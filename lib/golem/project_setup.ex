defmodule Golem.ProjectSetup do
  @moduledoc """
  Pre-run project setup: loads config, clones/pulls repos in the container,
  creates feature branches, and runs setup scripts.
  """

  require Logger

  @projects_path ".golem/projects.yml"
  @jira_path ".golem/jira.yml"

  @doc """
  Load project config from `.golem/projects.yml`.

  Returns `{:ok, %{bitbucket_workspace, projects, ...}}`.
  """
  def load_config do
    case YamlElixir.read_from_file(@projects_path) do
      {:ok, config} ->
        default_branch = config["default_branch"] || "main"
        {:ok, %{
          bitbucket_workspace: get_in(config, ["bitbucket", "workspace"]),
          projects: parse_projects(config["projects"] || [], default_branch)
        }}

      {:error, reason} ->
        {:error, "Failed to read #{@projects_path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Load project config merged with Jira settings from `.golem/jira.yml`.

  Returns `{:ok, %{bitbucket_workspace, projects, jira_base_url, ...}}`.
  """
  def load_config_with_jira do
    with {:ok, config} <- load_config(),
         {:ok, jira} <- load_jira_config() do
      {:ok, Map.merge(config, jira)}
    end
  end

  defp load_jira_config do
    case YamlElixir.read_from_file(@jira_path) do
      {:ok, config} ->
        {:ok, %{jira_base_url: get_in(config, ["jira", "base_url"])}}

      {:error, reason} ->
        {:error, "Failed to read #{@jira_path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Set up all projects in the container: configure git credentials,
  clone or pull repos, create feature branches, run setup scripts.
  """
  def setup_projects(config, ticket_key, summary) do
    branch = build_branch_name(ticket_key, summary)
    Logger.info("Setting up projects, branch: #{branch}")

    setup_git_credentials(config.bitbucket_workspace)

    results =
      Enum.map(config.projects, fn project ->
        case setup_project(project, branch, config.bitbucket_workspace) do
          :ok -> {:ok, project}
          {:error, reason} -> {:error, project.repo, reason}
        end
      end)

    errors = for {:error, repo, reason} <- results, do: "#{repo}: #{reason}"

    if errors == [] do
      {:ok, branch}
    else
      {:error, "Project setup failed:\n#{Enum.join(errors, "\n")}"}
    end
  end

  @doc """
  Build a branch name from ticket key and summary.
  Example: "golem/SA-1111-add-user-auth"
  """
  def build_branch_name(key, summary) do
    slug =
      summary
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)
      |> String.trim_trailing("-")

    "golem/#{key}-#{slug}"
  end

  # --- Private ---

  defp parse_projects(projects, default_branch) do
    Enum.map(projects, fn p ->
      %{
        repo: p["repo"],
        path: p["path"],
        description: p["description"],
        setup: p["setup"],
        branch_from: p["branch_from"] || default_branch
      }
    end)
  end

  defp setup_git_credentials(_workspace) do
    token = System.get_env("BITBUCKET_API_TOKEN") || raise "BITBUCKET_API_TOKEN not set"

    commands = [
      "git config --global credential.helper store",
      "echo 'https://x-token-auth:#{token}@bitbucket.org' > ~/.git-credentials",
      "chmod 600 ~/.git-credentials",
      "git config --global user.name '#{System.get_env("GIT_USER") || "Golem Bot"}'",
      "git config --global user.email '#{System.get_env("GIT_EMAIL") || "golem@bot.local"}'"
    ]

    Enum.each(commands, fn cmd ->
      case Golem.Sandbox.exec(cmd, timeout: 10_000) do
        {:ok, %{exit_code: 0}} -> :ok
        other -> Logger.warning("Git credential setup command failed: #{cmd} -> #{inspect(other)}")
      end
    end)
  end

  defp setup_project(project, branch, workspace) do
    repo_slug = project.repo |> String.split("/") |> List.last()
    clone_url = Golem.Bitbucket.clone_url(workspace, repo_slug)

    with :ok <- clone_or_pull(project.path, clone_url, project.branch_from),
         :ok <- create_branch(project.path, branch, project.branch_from),
         :ok <- run_setup_script(project.setup) do
      :ok
    end
  end

  defp clone_or_pull(path, clone_url, branch_from) do
    case Golem.Sandbox.exec("test -d #{path}/.git", timeout: 5_000) do
      {:ok, %{exit_code: 0}} ->
        # Repo exists — fetch and reset to base branch
        cmds = "cd #{path} && git fetch origin && git checkout #{branch_from} && git reset --hard origin/#{branch_from}"
        case Golem.Sandbox.exec(cmds, timeout: 60_000) do
          {:ok, %{exit_code: 0}} -> :ok
          {:ok, %{output: out}} -> {:error, "git pull failed: #{String.slice(out, 0, 200)}"}
          {:error, reason} -> {:error, "git pull error: #{inspect(reason)}"}
        end

      _ ->
        # Clone fresh
        case Golem.Sandbox.exec("git clone --branch #{branch_from} #{clone_url} #{path}", timeout: 120_000) do
          {:ok, %{exit_code: 0}} -> :ok
          {:ok, %{output: out}} -> {:error, "git clone failed: #{String.slice(out, 0, 200)}"}
          {:error, reason} -> {:error, "git clone error: #{inspect(reason)}"}
        end
    end
  end

  defp create_branch(path, branch, _branch_from) do
    case Golem.Sandbox.exec("cd #{path} && git checkout -b #{branch}", timeout: 10_000) do
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, %{output: out}} ->
        if String.contains?(out, "already exists") do
          # Branch exists, just check it out
          case Golem.Sandbox.exec("cd #{path} && git checkout #{branch}", timeout: 10_000) do
            {:ok, %{exit_code: 0}} -> :ok
            {:ok, %{output: out2}} -> {:error, "git checkout failed: #{String.slice(out2, 0, 200)}"}
            {:error, reason} -> {:error, inspect(reason)}
          end
        else
          {:error, "git branch create failed: #{String.slice(out, 0, 200)}"}
        end
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp run_setup_script(nil), do: :ok

  defp run_setup_script(script_path) do
    # Read the script from host and execute in container
    case File.read(script_path) do
      {:ok, content} ->
        Logger.info("Running setup script: #{script_path}")
        # Write script to container and execute
        tmp_path = "/tmp/golem_setup_#{:crypto.strong_rand_bytes(4) |> Base.encode16()}.sh"

        with :ok <- Golem.Sandbox.write_file(tmp_path, content),
             {:ok, %{exit_code: 0}} <- Golem.Sandbox.exec("chmod +x #{tmp_path} && #{tmp_path}", timeout: 300_000) do
          :ok
        else
          {:ok, %{exit_code: code, output: out}} ->
            {:error, "Setup script #{script_path} failed (exit #{code}): #{String.slice(out, 0, 500)}"}

          {:error, reason} ->
            {:error, "Setup script error: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Cannot read setup script #{script_path}: #{inspect(reason)}"}
    end
  end
end
