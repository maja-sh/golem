defmodule Golem.Discord.Commander do
  @moduledoc """
  Parses Discord messages into commands and dispatches them.
  """

  require Logger

  @commands ~w(run resume status stop runs fix)

  @doc """
  Parse a message into a command. Returns {:command, cmd, args} or :not_command.
  """
  def parse(content) do
    content = String.trim(content)

    case String.split(content, ~r/\s+/, parts: 2) do
      [cmd | rest] when cmd in @commands ->
        args = List.first(rest, "")
        {:command, String.to_atom(cmd), args}

      _ ->
        :not_command
    end
  end

  @doc """
  Execute a parsed command. Returns a response string for Discord.
  """
  def execute(:run, args) do
    # Check if it's a scenario name or a quoted goal
    {goal, opts} = parse_run_args(args)

    case Golem.DaemonRunner.start_run(goal, opts) do
      {:ok, run_id} ->
        "🔧 Started run `#{run_id}`\n#{String.slice(goal, 0, 200)}"

      {:error, :busy} ->
        status = Golem.DaemonRunner.status()
        "❌ A job is already running: `#{status.run_id}`\nUse `stop` first, or wait for it to finish."
    end
  end

  def execute(:resume, args) do
    run_id =
      case String.trim(args) do
        "" ->
          # Resume most recent run
          case Golem.State.list_runs() |> Enum.reject(& &1.id =~ "test") do
            [latest | _] -> latest.id
            [] -> nil
          end

        id -> id
      end

    if run_id do
      case Golem.DaemonRunner.resume_run(run_id) do
        {:ok, _} -> "🔧 Resuming run `#{run_id}`"
        {:error, :busy} -> "❌ A job is already running. Use `stop` first."
        {:error, :not_found} -> "❌ Run `#{run_id}` not found."
      end
    else
      "❌ No saved runs found."
    end
  end

  def execute(:status, _args) do
    status = Golem.DaemonRunner.status()

    case status.status do
      :idle ->
        "💤 Idle — no active job."

      :running ->
        elapsed =
          if status.started_at do
            seconds = DateTime.diff(DateTime.utc_now(), status.started_at)
            if seconds < 60, do: "#{seconds}s", else: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
          else
            "unknown"
          end

        "🔧 **Running** `#{status.run_id}`\n⏱ #{elapsed}\n📋 #{status.goal}"
    end
  end

  def execute(:stop, _args) do
    case Golem.DaemonRunner.stop_run() do
      :ok -> "⏸️ Stop requested — saving state..."
      {:error, :not_running} -> "💤 No job is running."
    end
  end

  def execute(:runs, _args) do
    runs = Golem.State.list_runs() |> Enum.reject(& &1.id =~ "test") |> Enum.take(10)

    if runs == [] do
      "No saved runs."
    else
      lines = Enum.map(runs, fn r ->
        "• `#{r.id}` step #{r.step}/#{r.max_steps} — #{String.slice(r.goal, 0, 60)}"
      end)
      "**Saved runs:**\n#{Enum.join(lines, "\n")}"
    end
  end

  def execute(:fix, args) do
    case String.split(args, ":", parts: 2) do
      [project, description] ->
        project = String.trim(project)
        description = String.trim(description)
        goal = "Fix the following issue in the project at /home/agent/#{project}: #{description}"
        execute(:run, "\"#{goal}\"")

      _ ->
        "❌ Usage: `fix <project>: <description>`\nExample: `fix chainpost: the P2P sync test is failing`"
    end
  end

  # --- Helpers ---

  defp parse_run_args(args) do
    args = String.trim(args)

    cond do
      # Quoted goal: run "Build a web server"
      String.starts_with?(args, "\"") ->
        goal = String.trim(args, "\"")
        {goal, []}

      # Scenario name: run smoke_maze
      # Optionally with --max-steps
      true ->
        {opts, rest} = parse_opts(args)
        scenario_or_goal = String.trim(Enum.join(rest, " "))

        case load_scenario(scenario_or_goal) do
          {:ok, goal} -> {goal, opts}
          :not_found -> {scenario_or_goal, opts}
        end
    end
  end

  defp parse_opts(args) do
    parts = String.split(args)
    parse_opts(parts, [], [])
  end

  defp parse_opts(["--max-steps", n | rest], opts, args) do
    parse_opts(rest, [{:max_steps, String.to_integer(n)} | opts], args)
  end

  defp parse_opts([arg | rest], opts, args) do
    parse_opts(rest, opts, args ++ [arg])
  end

  defp parse_opts([], opts, args), do: {opts, args}

  defp load_scenario(name) do
    path = Path.join("scenarios", "#{name}.md")

    case File.read(path) do
      {:ok, content} ->
        goal = case Regex.run(~r/## Goal\s*\n(.*)/s, content) do
          [_, g] -> String.trim(g)
          nil -> String.trim(content)
        end
        {:ok, goal}

      {:error, _} ->
        :not_found
    end
  end
end
