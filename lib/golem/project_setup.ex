defmodule Golem.ProjectSetup do
  @moduledoc """
  Pre-run project setup: loads config, clones/pulls repos in the container,
  creates feature branches, and runs setup scripts.
  """

  require Logger

  @doc """
  Load project config from `.golem/config.yaml`.

  Returns `{:ok, %{bitbucket_workspace, projects, ...}}` or
  `{:error, reason}` if the file is missing the `projects:` block.
  """
  def load_config do
    unified = Golem.Config.raw_yaml()

    if is_list(unified["projects"]) do
      default_branch = unified["default_branch"] || "main"

      {:ok,
       %{
         bitbucket_workspace: get_in(unified, ["bitbucket", "workspace"]),
         projects: parse_projects(unified["projects"], default_branch)
       }}
    else
      {:error,
       "No `projects:` block in .golem/config.yaml. See .golem/config.example.yaml for the format."}
    end
  end

  @doc """
  Load project config merged with Jira settings from `.golem/config.yaml`.

  Returns `{:ok, %{bitbucket_workspace, projects, jira_base_url, ...}}`.
  """
  def load_config_with_jira do
    with {:ok, config} <- load_config(),
         {:ok, jira} <- load_jira_config() do
      {:ok, Map.merge(config, jira)}
    end
  end

  defp load_jira_config do
    unified = Golem.Config.raw_yaml()

    case unified["jira"] do
      jira when is_map(jira) ->
        {:ok,
         %{
           jira_base_url: jira["base_url"],
           jira_done_transition: jira["done_transition"] || "Done"
         }}

      _ ->
        {:error,
         "No `jira:` block in .golem/config.yaml. See .golem/config.example.yaml for the format."}
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

  @repos_dir "/home/agent/repos"
  @tasks_dir "/home/agent/tasks"

  @doc """
  Set up all projects in the container using git worktrees.

  Main clones live in #{@repos_dir}/{slug} (persistent, always on default branch).
  Each task gets isolated worktrees in #{@tasks_dir}/{ticket_key}/{slug}.
  Setup scripts run against the worktree paths.

  Returns `{:ok, branch, updated_projects}` where updated_projects has worktree paths.
  """
  def setup_projects(config, ticket_key, summary) do
    branch = build_branch_name(ticket_key, summary)
    Logger.info("Setting up projects, branch: #{branch}")

    setup_git_credentials(config.bitbucket_workspace, false)

    results =
      Enum.map(config.projects, fn project ->
        case setup_project_worktree(project, branch, ticket_key, config.bitbucket_workspace) do
          {:ok, worktree_path} ->
            {:ok, %{project | path: worktree_path}}
          {:error, reason} ->
            {:error, project.repo, reason}
        end
      end)

    errors = for {:error, repo, reason} <- results, do: "#{repo}: #{reason}"

    if errors == [] do
      updated_projects = for {:ok, project} <- results, do: project
      {:ok, branch, %{config | projects: updated_projects}}
    else
      {:error, "Project setup failed:\n#{Enum.join(errors, "\n")}"}
    end
  end

  @doc """
  Set up a worktree on an existing branch (the PR's source branch).
  Used by `mix golem.iterate` — we don't create a new branch, we
  check out the one the bot already pushed.

  Reuses the same `tasks/<key>/<repo>` layout so the agent's mental
  model stays consistent across new-ticket runs and iteration runs.

  Returns `{:ok, branch, %{config | projects: [updated_project]}}`.
  """
  def setup_iterate_worktree(config, project, pr, ticket_key) do
    setup_git_credentials(config.bitbucket_workspace, false)

    branch = pr.source_branch
    repo_slug = project.repo |> String.split("/") |> List.last()
    clone_url = Golem.Bitbucket.clone_url(config.bitbucket_workspace, repo_slug)
    repo_path = "#{@repos_dir}/#{repo_slug}"
    worktree_path = "#{@tasks_dir}/#{ticket_key}/#{repo_slug}"
    cuser = container_user()

    with :ok <- ensure_main_clone(repo_path, clone_url, project.branch_from),
         :ok <- ensure_branch_fetched(repo_path, branch),
         :ok <- create_review_worktree(repo_path, worktree_path, branch),
         :ok <- copy_cached_deps(repo_path, worktree_path, project[:cache] || []),
         :ok <- run_cmd("chown -R #{cuser}:#{cuser} #{worktree_path}", timeout: 60_000, verbose: false),
         :ok <- run_setup_script(project.setup, worktree_path, false) do
      updated = %{project | path: worktree_path}
      {:ok, branch, %{config | projects: [updated]}}
    end
  end

  # Main clones default to a single-branch shallow fetch. To check out
  # an existing feature branch we first need to fetch it explicitly.
  # The `+` prefix forces the local remote-tracking ref to whatever
  # origin currently has — we don't keep local commits on the main
  # clone (real work lives in worktrees), so a non-fast-forward from
  # origin is always something we want to accept rather than block on.
  defp ensure_branch_fetched(repo_path, branch) do
    cmd = "cd #{repo_path} && git fetch origin +#{branch}:refs/remotes/origin/#{branch}"
    run_cmd(cmd, timeout: 600_000, verbose: false)
  end

  defp create_review_worktree(repo_path, worktree_path, branch) do
    # Clean any prior worktree at this path (could be a stale one from
    # a previous run on the same ticket).
    Golem.Sandbox.exec(
      "cd #{repo_path} && git worktree remove --force #{worktree_path} 2>/dev/null; rm -rf #{worktree_path}",
      timeout: 30_000
    )

    run_cmd("mkdir -p #{Path.dirname(worktree_path)}", timeout: 5_000, verbose: false)

    # Track the existing remote branch — no -b, so we don't create a
    # new local branch with the same name (which would conflict). The
    # leading `git branch -D` clears any stale local pointer.
    cmd =
      "cd #{repo_path} && git branch -D #{branch} 2>/dev/null; " <>
        "git worktree add #{worktree_path} -B #{branch} origin/#{branch}"

    run_cmd(cmd, timeout: 30_000, verbose: false)
  end

  @doc """
  Clean up worktrees for a completed task.
  """
  def cleanup_worktrees(ticket_key) do
    task_dir = "#{@tasks_dir}/#{ticket_key}"

    # Remove worktrees from their parent repos first
    case Golem.Sandbox.exec("ls #{task_dir} 2>/dev/null", timeout: 5_000) do
      {:ok, %{exit_code: 0, output: output}} when byte_size(output) > 0 ->
        output
        |> String.split("\n", trim: true)
        |> Enum.each(fn slug ->
          worktree_path = "#{task_dir}/#{slug}"
          repo_path = "#{@repos_dir}/#{slug}"
          Golem.Sandbox.exec("cd #{repo_path} && git worktree remove --force #{worktree_path} 2>/dev/null", timeout: 10_000)
        end)
      _ -> :ok
    end

    # Remove the task directory
    Golem.Sandbox.exec("rm -rf #{task_dir}", timeout: 30_000)
    :ok
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
        branch_from: p["branch_from"] || default_branch,
        instructions: p["instructions"],
        cache: p["cache"] || []
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

  defp setup_project_worktree(project, branch, ticket_key, workspace) do
    repo_slug = project.repo |> String.split("/") |> List.last()
    clone_url = Golem.Bitbucket.clone_url(workspace, repo_slug)
    repo_path = "#{@repos_dir}/#{repo_slug}"
    worktree_path = "#{@tasks_dir}/#{ticket_key}/#{repo_slug}"
    cuser = container_user()

    with :ok <- ensure_main_clone(repo_path, clone_url, project.branch_from),
         :ok <- create_worktree(repo_path, worktree_path, branch, project.branch_from),
         :ok <- copy_cached_deps(repo_path, worktree_path, project[:cache] || []),
         :ok <- run_cmd("chown -R #{cuser}:#{cuser} #{worktree_path}", timeout: 60_000, verbose: false),
         :ok <- run_setup_script(project.setup, worktree_path, false) do
      {:ok, worktree_path}
    end
  end

  # Ensure the main clone exists and is up to date. Reuses existing
  # clone; fetches origin and fast-forwards the local `branch_from`
  # ref to match the remote so worktrees branched off it (and any
  # `git log <branch_from>..HEAD` reports the agent runs) reflect the
  # true upstream state. Clones are full-history — shallow clones lose
  # blame/log context that the agent uses for repo understanding.
  defp ensure_main_clone(repo_path, clone_url, branch_from) do
    cuser = container_user()

    case Golem.Sandbox.exec("test -d #{repo_path}/.git", timeout: 5_000) do
      {:ok, %{exit_code: 0}} ->
        with :ok <- maybe_unshallow(repo_path),
             :ok <- run_cmd("cd #{repo_path} && git fetch origin --tags", timeout: 600_000, verbose: false) do
          # Fast-forward local branch_from to origin/branch_from.
          # update-ref works regardless of the clone's current HEAD —
          # the main clone is a parking spot for worktrees, not a
          # checkout the user works in.
          run_cmd(
            "cd #{repo_path} && git update-ref refs/heads/#{branch_from} refs/remotes/origin/#{branch_from}",
            timeout: 10_000,
            verbose: false
          )
        end

      _ ->
        # Fresh clone. `--progress` forces git to emit progress output
        # on stderr even when not attached to a TTY — without it, slow
        # networks (airplane wifi, hotspot) silently download the pack
        # and trip the 120 s stall detector.
        run_cmd("mkdir -p #{@repos_dir}", timeout: 5_000, verbose: false)
        cmd = "git clone --progress --branch #{branch_from} #{clone_url} #{repo_path}"
        display = String.replace(cmd, ~r/x-bitbucket-api-token-auth:[^@]+@/, "x-bitbucket-api-token-auth:<token>@")
        with :ok <- run_cmd(cmd, timeout: 1_800_000, verbose: false, display: display) do
          run_cmd("chown -R #{cuser}:#{cuser} #{repo_path}", timeout: 60_000, verbose: false)
        end
    end
  end

  # Detect and deepen any pre-existing shallow clone left behind by an
  # earlier `--depth 1` run. `--unshallow` is a one-shot — once the
  # repo is full, subsequent fetches just fast-forward normally.
  defp maybe_unshallow(repo_path) do
    case Golem.Sandbox.exec("cd #{repo_path} && git rev-parse --is-shallow-repository", timeout: 5_000) do
      {:ok, %{exit_code: 0, output: output}} ->
        if String.trim(output) == "true" do
          Logger.info("Unshallowing #{repo_path}...")
          run_cmd("cd #{repo_path} && git fetch --unshallow origin --tags", timeout: 1_800_000, verbose: false)
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  # Create a worktree for the feature branch
  defp create_worktree(repo_path, worktree_path, branch, branch_from) do
    # Clean up existing worktree if present
    Golem.Sandbox.exec("cd #{repo_path} && git worktree remove --force #{worktree_path} 2>/dev/null; rm -rf #{worktree_path}", timeout: 30_000)
    run_cmd("mkdir -p #{Path.dirname(worktree_path)}", timeout: 5_000, verbose: false)

    # Create branch from latest origin and add worktree
    cmd = "cd #{repo_path} && git branch -D #{branch} 2>/dev/null; git worktree add -b #{branch} #{worktree_path} origin/#{branch_from}"
    run_cmd(cmd, timeout: 30_000, verbose: false)
  end

  defp clone_or_pull(path, clone_url, branch_from, verbose) do
    # Remove existing directory for a clean clone
    Golem.Sandbox.exec("rm -rf #{path}", timeout: 60_000)

    cmd = "git clone --progress --branch #{branch_from} #{clone_url} #{path}"
    display = String.replace(cmd, ~r/x-bitbucket-api-token-auth:[^@]+@/, "x-bitbucket-api-token-auth:<token>@")
    result = run_cmd(cmd, timeout: 1_800_000, verbose: verbose, display: display)

    # Git runs as root via sandbox — fix ownership so agent user can work with the files
    with :ok <- result do
      cuser = container_user()
      run_cmd("chown -R #{cuser}:#{cuser} #{path}", timeout: 60_000, verbose: false)
    end
  end

  # Copy cached directories from main clone to worktree so dependency
  # installs are fast (just verifies, doesn't re-download)
  defp copy_cached_deps(_repo_path, _worktree_path, []), do: :ok
  defp copy_cached_deps(repo_path, worktree_path, dirs) do
    for dir <- dirs do
      Golem.Sandbox.exec(
        "test -d #{repo_path}/#{dir} && cp -a #{repo_path}/#{dir} #{worktree_path}/#{dir}",
        timeout: 120_000
      )
    end
    :ok
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
