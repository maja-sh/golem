defmodule Mix.Tasks.Golem.Setup do
  @moduledoc """
  Test project setup from .golem/projects.yml without running the agent.

  Loads the config, clones/pulls all projects into the container,
  runs setup scripts, and prints the layout. Stays on the default branch.

  ## Usage

      mix golem.setup
  """

  use Mix.Task

  @shortdoc "Test project setup (clone repos, run setup scripts, no agent run)"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    # Suppress console logger — keep only file logger
    for id <- :logger.get_handler_ids(), id != :golem_file do
      :logger.set_handler_config(id, :level, :none)
    end

    case Golem.ProjectSetup.load_config() do
      {:ok, config} ->
        puts([:cyan, "● ", :reset, :bright, "Project setup", :reset])
        puts([])

        puts([:yellow, "+ Loading config...", :reset])
        for p <- config.projects do
          desc = if p.description, do: " — #{p.description}", else: ""
          puts([:faint, "  #{p.repo}#{desc} (#{p.branch_from})", :reset])
        end
        puts([])

        puts([:yellow, "+ Configuring git credentials...", :reset])
        Golem.ProjectSetup.setup_credentials(config)
        puts([:green, "  ✓ ", :reset, :faint, "credentials configured", :reset])

        errors =
          Enum.reduce(config.projects, [], fn project, errors ->
            puts([])
            puts([:white, "  #{project.repo}", :reset])

            case clone_project(project, config) do
              :ok -> errors
              {:error, reason} -> ["#{project.repo}: #{reason}" | errors]
            end
          end)

        puts([])
        if errors == [] do
          puts([:green, :bright, "✓ Setup complete", :reset])
        else
          puts([:red, :bright, "✗ Setup failed", :reset])
          for e <- Enum.reverse(errors), do: puts([:red, "  #{e}", :reset])
        end

      {:error, reason} ->
        puts([:red, "✗ Failed to load config: #{inspect(reason)}", :reset])
    end
  end

  defp clone_project(project, config) do
    repo_slug = project.repo |> String.split("/") |> List.last()
    clone_url = Golem.Bitbucket.clone_url(config.bitbucket_workspace, repo_slug)

    with :ok <- do_clone(project, clone_url),
         :ok <- do_setup(project) do
      :ok
    end
  end

  defp do_clone(project, clone_url) do
    result =
      case Golem.Sandbox.exec("test -d #{project.path}/.git", timeout: 5_000) do
        {:ok, %{exit_code: 0}} ->
          cmd = "cd #{project.path} && git fetch origin && git checkout #{project.branch_from} && git reset --hard origin/#{project.branch_from}"
          run_step("pull #{project.branch_from}", cmd)

        _ ->
          cmd = "git clone --branch #{project.branch_from} #{clone_url} #{project.path}"
          run_step("clone (#{project.branch_from})", cmd)
      end

    # Git runs as root via sandbox — fix ownership so agent user can work with the files
    with :ok <- result do
      cuser = Application.get_env(:golem, :container_user, "agent")
      Golem.Sandbox.exec("chown -R #{cuser}:#{cuser} #{project.path}", timeout: 60_000)
      :ok
    end
  end

  defp do_setup(%{setup: nil}), do: :ok
  defp do_setup(%{setup: []}), do: :ok

  defp do_setup(%{setup: steps}) when is_list(steps) do
    Enum.reduce_while(steps, :ok, fn {label, command, user}, :ok ->
      cmd = wrap_user(command, user)
      case run_step(label, cmd, timeout: 300_000) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp do_setup(%{setup: script_path}) when is_binary(script_path) do
    case File.read(script_path) do
      {:ok, content} ->
        tmp = "/tmp/golem_setup_#{:crypto.strong_rand_bytes(4) |> Base.encode16()}.sh"
        with :ok <- Golem.Sandbox.write_file(tmp, content) do
          run_step("setup (#{Path.basename(script_path)})", "chmod +x #{tmp} && #{tmp}", timeout: 300_000)
        end

      {:error, reason} ->
        {:error, "Cannot read #{script_path}: #{inspect(reason)}"}
    end
  end

  defp run_step(label, cmd, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)

    case Golem.Sandbox.exec(cmd, timeout: timeout) do
      {:ok, %{output: output, exit_code: 0}} ->
        summary = output |> String.trim() |> oneliner()
        detail = if summary != "", do: [:faint, " · #{summary}", :reset], else: []
        puts([:green, "  ✓ ", :reset, :faint, label, :reset] ++ detail)
        :ok

      {:ok, %{output: output, exit_code: code}} ->
        puts([:red, "  ✗ #{label} ", :reset, :faint, "(exit #{code})", :reset])
        output |> String.trim() |> error_detail() |> Enum.each(fn line ->
          puts([:faint, :red, "    #{line}", :reset])
        end)
        {:error, "#{label} failed (exit #{code})"}

      {:error, {:timeout, _}} ->
        puts([:red, "  ✗ #{label} ", :reset, :faint, "(timed out)", :reset])
        {:error, "#{label} timed out"}

      {:error, reason} ->
        puts([:red, "  ✗ #{label} ", :reset, :faint, "#{inspect(reason)}", :reset])
        {:error, inspect(reason)}
    end
  end

  defp wrap_user(command, nil), do: command
  defp wrap_user(command, user) do
    escaped = String.replace(command, "'", "'\\''")
    "runuser -u #{user} -- bash -c '#{escaped}'"
  end

  defp puts(tokens) do
    IO.puts(IO.ANSI.format(tokens))
  end

  defp oneliner(text) do
    lines = String.split(text, "\n", trim: true)
    case lines do
      [] -> ""
      [one] -> String.slice(one, 0, 80)
      _ ->
        last = List.last(lines) |> String.slice(0, 60)
        "#{length(lines)} lines · #{last}"
    end
  end

  defp error_detail(text) do
    lines = String.split(text, "\n", trim: true)
    if length(lines) > 30 do
      first = Enum.take(lines, 5)
      last = Enum.take(lines, -20)
      first ++ ["... (#{length(lines) - 25} lines omitted)"] ++ last
    else
      lines
    end
  end
end
