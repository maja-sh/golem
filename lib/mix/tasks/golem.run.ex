defmodule Mix.Tasks.Golem.Run do
  @moduledoc """
  Run the autonomous agent with a goal.

  ## Usage

      mix golem.run "Build a web scraper in Python"
      mix golem.run --scenario smoke_maze
      mix golem.run --plan plan.md "Build a web scraper in Python"
      mix golem.run --max-steps 50 "Set up a Phoenix project"
      mix golem.run --jira SA-1111
  """

  use Mix.Task

  @shortdoc "Run the autonomous agent with a goal"

  @impl true
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [plan: :string, max_steps: :integer, scenario: :string, jira: :string, force: :boolean],
        aliases: [p: :plan, s: :max_steps, S: :scenario, j: :jira, f: :force]
      )

    # Start the application
    Mix.Task.run("app.start")

    # Suppress console logger — keep only file logger
    for id <- :logger.get_handler_ids(), id != :golem_file do
      :logger.set_handler_config(id, :level, :none)
    end

    if opts[:jira] do
      run_jira(opts[:jira], opts)
    else
      run_standard(opts, rest)
    end
  end

  defp run_jira(ticket_key, opts) do
    runner_opts =
      (case opts[:max_steps] do
        nil -> []
        n -> [max_steps: n]
      end) ++
      (if opts[:force], do: [skip_eval: true], else: [])

    case Golem.Jira.Integration.run(ticket_key, runner_opts) do
      {:ok, _} -> :ok
      {:error, :max_steps_reached} -> :ok
      {:error, reason} ->
        Mix.shell().error("\n✗ #{format_error(reason)}")
    end
  end

  defp run_standard(opts, rest) do
    goal =
      case opts[:scenario] do
        nil ->
          Enum.join(rest, " ")

        name ->
          path = Path.join("scenarios", "#{name}.md")

          case File.read(path) do
            {:ok, content} -> extract_goal(content)
            {:error, _} ->
              Mix.shell().error("Scenario not found: #{path}")
              Mix.shell().info("Available: #{list_scenarios()}")
              exit({:shutdown, 1})
          end
      end

    if goal == "" do
      Mix.shell().error("Usage: mix golem.run \"your goal here\"")
      Mix.shell().error("       mix golem.run --scenario smoke_maze")
      Mix.shell().error("       mix golem.run --jira SA-1111")
      exit({:shutdown, 1})
    end

    # Load plan from file if provided
    runner_opts =
      case opts[:plan] do
        nil ->
          []

        path ->
          case File.read(path) do
            {:ok, plan} -> [plan: plan]
            {:error, reason} ->
              Mix.shell().error("Failed to read plan file #{path}: #{inspect(reason)}")
              exit({:shutdown, 1})
          end
      end

    runner_opts =
      case opts[:max_steps] do
        nil -> runner_opts
        n -> Keyword.put(runner_opts, :max_steps, n)
      end

    case Golem.run(goal, runner_opts) do
      {:ok, _} -> :ok          # TUI handles it
      {:error, :max_steps_reached} -> :ok  # TUI handles it
      {:error, reason} ->
        Mix.shell().error("\n✗ #{format_error(reason)}")
    end
  end

  # Extract the goal text from a scenario markdown file (content under ## Goal)
  defp extract_goal(content) do
    case Regex.run(~r/## Goal\s*\n(.*)/s, content) do
      [_, goal] -> String.trim(goal)
      nil -> String.trim(content)
    end
  end

  defp format_error(:planner_max_steps), do: "Planner hit max exploration steps — increase :planner_max_steps config"
  defp format_error(:ticket_rejected), do: "Ticket was rejected by evaluator"
  defp format_error(:budget_exceeded), do: "Cost budget exceeded"
  defp format_error(:stopped), do: "Run was stopped"
  defp format_error({status, %{"error" => %{"message" => msg}}}) when is_integer(status), do: msg
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp list_scenarios do
    case File.ls("scenarios") do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&String.replace_suffix(&1, ".md", ""))
        |> Enum.join(", ")

      _ ->
        "(none found)"
    end
  end
end
