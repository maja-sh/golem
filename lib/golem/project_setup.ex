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
  Clone/pull all projects and run setup scripts. Stays on the default branch.
  Use this to verify project config without starting a run.
  """
  def clone_projects(config) do
    IO.puts("Configuring git credentials...")
    setup_git_credentials(config.bitbucket_workspace, true)

    results =
      Enum.map(config.projects, fn project ->
        repo_slug = project.repo |> String.split("/") |> List.last()
        clone_url = Golem.Bitbucket.clone_url(config.bitbucket_workspace, repo_slug)

        IO.puts("\n--- #{project.repo} ---")
        with :ok <- clone_or_pull(project.path, clone_url, project.branch_from, true),
             :ok <- run_setup_script(project.setup, project.path, true) do
          IO.puts("  ✓ #{project.repo} ready")
          {:ok, project}
        else
          {:error, reason} ->
            IO.puts("  ✗ #{project.repo} failed: #{reason}")
            {:error, project.repo, reason}
        end
      end)

    errors = for {:error, repo, reason} <- results, do: "#{repo}: #{reason}"

    if errors == [] do
      :ok
    else
      {:error, "Project setup failed:\n#{Enum.join(errors, "\n")}"}
    end
  end

  @doc """
  Set up all projects in the container: configure git credentials,
  clone or pull repos, create feature branches, run setup scripts.
  """
  def setup_projects(config, ticket_key, summary) do
    branch = build_branch_name(ticket_key, summary)
    Logger.info("Setting up projects, branch: #{branch}")

    setup_git_credentials(config.bitbucket_workspace, false)

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

  defp container_user, do: Application.get_env(:golem, :container_user, "agent")

  defp parse_projects(projects, default_branch) do
    Enum.map(projects, fn p ->
      %{
        repo: p["repo"],
        path: p["path"],
        description: p["description"],
        setup: parse_setup(p["setup"]),
        branch_from: p["branch_from"] || default_branch
      }
    end)
  end

  @doc "Configure git credentials in the container."
  def setup_credentials(config) do
    setup_git_credentials(config.bitbucket_workspace, false)
  end

  defp setup_git_credentials(_workspace, verbose) do
    token = System.get_env("BITBUCKET_API_TOKEN") || raise "BITBUCKET_API_TOKEN not set"
    user = System.get_env("GIT_USER") || "Golem Bot"
    email = System.get_env("GIT_EMAIL") || "golem@bot.local"
    cuser = container_user()
    cred_line = "https://x-bitbucket-api-token-auth:#{token}@bitbucket.org"
    display_cred = "https://x-bitbucket-api-token-auth:<token>@bitbucket.org"

    # Configure git for both root (sandbox exec user) and container user (project file owner)
    for {home, run_as} <- [{"/root", "root"}, {"/home/#{cuser}", cuser}] do
      commands = [
        {"git config --global --add safe.directory '*'",
         "git config --global --add safe.directory '*'"},
        {"git config --global credential.helper store",
         "git config --global credential.helper store"},
        {"echo '#{display_cred}' > #{home}/.git-credentials",
         "echo '#{cred_line}' > #{home}/.git-credentials"},
        {"chmod 600 #{home}/.git-credentials",
         "chmod 600 #{home}/.git-credentials"},
        {"git config --global user.name '#{user}'",
         "git config --global user.name '#{user}'"},
        {"git config --global user.email '#{email}'",
         "git config --global user.email '#{email}'"},
        {"git config --global url.\"#{display_cred}/\".insteadOf \"git@bitbucket.org:\"",
         "git config --global url.\"#{cred_line}/\".insteadOf \"git@bitbucket.org:\""}
      ]

      Enum.each(commands, fn {display_cmd, real_cmd} ->
        if verbose, do: IO.puts("  $ #{display_cmd}")
        full_cmd = "runuser -u #{run_as} -- bash -c '#{String.replace(real_cmd, "'", "'\\''")}'"
        case Golem.Sandbox.exec(full_cmd, timeout: 10_000) do
          {:ok, %{exit_code: 0}} -> :ok
          other -> Logger.warning("Git credential setup failed (#{run_as}): #{display_cmd} -> #{inspect(other)}")
        end
      end)
    end
  end

  defp setup_project(project, branch, workspace) do
    repo_slug = project.repo |> String.split("/") |> List.last()
    clone_url = Golem.Bitbucket.clone_url(workspace, repo_slug)

    with :ok <- clone_or_pull(project.path, clone_url, project.branch_from, false),
         :ok <- create_branch(project.path, branch, project.branch_from),
         :ok <- run_setup_script(project.setup, project.path, false) do
      :ok
    end
  end

  defp clone_or_pull(path, clone_url, branch_from, verbose) do
    # Remove existing directory for a clean clone
    Golem.Sandbox.exec("rm -rf #{path}", timeout: 60_000)

    cmd = "git clone --branch #{branch_from} #{clone_url} #{path}"
    display = String.replace(cmd, ~r/x-bitbucket-api-token-auth:[^@]+@/, "x-bitbucket-api-token-auth:<token>@")
    result = run_cmd(cmd, timeout: 120_000, verbose: verbose, display: display)

    # Git runs as root via sandbox — fix ownership so agent user can work with the files
    with :ok <- result do
      cuser = container_user()
      run_cmd("chown -R #{cuser}:#{cuser} #{path}", timeout: 60_000, verbose: false)
    end
  end

  defp create_branch(path, branch, _branch_from) do
    case Golem.Sandbox.exec("cd #{path} && git checkout -b #{branch}", timeout: 10_000) do
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, %{output: out}} ->
        if String.contains?(out, "already exists") do
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

  defp run_setup_script(nil, _path, _verbose), do: :ok
  defp run_setup_script([], _path, _verbose), do: :ok

  # List of steps: [{label, command, user}, ...]
  defp run_setup_script(steps, path, verbose) when is_list(steps) do
    Enum.reduce_while(steps, :ok, fn {label, command, user}, :ok ->
      cmd = "cd #{path} && #{command}" |> wrap_user(user)
      case run_cmd(cmd, timeout: 300_000, verbose: verbose, display: label) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Legacy: single script path
  defp run_setup_script(script_path, _path, verbose) when is_binary(script_path) do
    case File.read(script_path) do
      {:ok, content} ->
        if verbose, do: IO.puts("  Running setup script: #{script_path}")
        tmp_path = "/tmp/golem_setup_#{:crypto.strong_rand_bytes(4) |> Base.encode16()}.sh"

        with :ok <- Golem.Sandbox.write_file(tmp_path, content) do
          run_cmd("chmod +x #{tmp_path} && #{tmp_path}", timeout: 300_000, verbose: verbose, display: script_path)
        end

      {:error, reason} ->
        {:error, "Cannot read setup script #{script_path}: #{inspect(reason)}"}
    end
  end

  defp parse_setup(nil), do: nil
  defp parse_setup(path) when is_binary(path), do: path
  defp parse_setup(steps) when is_list(steps) do
    Enum.map(steps, fn
      %{"label" => label, "run" => command, "user" => user} -> {label, command, user}
      %{"label" => label, "run" => command} -> {label, command, nil}
      %{"run" => command, "user" => user} -> {command, command, user}
      %{"run" => command} -> {command, command, nil}
    end)
  end

  defp wrap_user(command, nil), do: command
  defp wrap_user(command, user) do
    escaped = String.replace(command, "'", "'\\''")
    "runuser -u #{user} -- bash -c '#{escaped}'"
  end

  defp run_cmd(cmd, opts) do
    verbose = Keyword.get(opts, :verbose, false)
    display = Keyword.get(opts, :display, cmd)
    timeout = Keyword.get(opts, :timeout, 60_000)

    if verbose, do: IO.puts("  $ #{display}")

    case Golem.Sandbox.exec(cmd, timeout: timeout) do
      {:ok, %{output: output, exit_code: 0}} ->
        if verbose and output != "" do
          output |> String.trim() |> truncate_output() |> IO.puts()
        end
        :ok

      {:ok, %{output: output, exit_code: code}} ->
        if verbose do
          IO.puts("  [exit #{code}]")
          if output != "", do: output |> String.trim() |> truncate_output(:error) |> IO.puts()
        end
        {:error, "[exit #{code}] #{String.slice(output, 0, 300)}"}

      {:error, {:timeout, partial}} ->
        if verbose, do: IO.puts("  [timed out]")
        {:error, "Command timed out. Partial: #{String.slice(partial, 0, 200)}"}

      {:error, reason} ->
        if verbose, do: IO.puts("  [error] #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  defp truncate_output(text, mode \\ :ok)

  defp truncate_output(text, :error) do
    lines = String.split(text, "\n")
    if length(lines) > 40 do
      first = Enum.take(lines, 5)
      last = Enum.take(lines, -30)
      indent = fn l -> "    #{l}" end
      (Enum.map(first, indent) ++ ["    ... (#{length(lines) - 35} lines omitted)"] ++ Enum.map(last, indent))
      |> Enum.join("\n")
    else
      lines |> Enum.map(fn l -> "    #{l}" end) |> Enum.join("\n")
    end
  end

  defp truncate_output(text, :ok) do
    lines = String.split(text, "\n")
    if length(lines) > 10 do
      first = Enum.take(lines, 3)
      last = Enum.take(lines, -5)
      indent = fn l -> "    #{l}" end
      (Enum.map(first, indent) ++ ["    ... (#{length(lines) - 8} lines omitted)"] ++ Enum.map(last, indent))
      |> Enum.join("\n")
    else
      lines |> Enum.map(fn l -> "    #{l}" end) |> Enum.join("\n")
    end
  end
end
