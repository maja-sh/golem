defmodule Golem.CLI.Run do
  @moduledoc """
  Run the autonomous agent with a goal.

  Usage:

      golem run "Build a web scraper in Python"
      golem run --scenario smoke_maze
      golem run --plan plan.md "Build a web scraper in Python"
      golem run --max-steps 50 "Set up a Phoenix project"
      golem run --jira SA-1111
      golem run --jira SA-1111 --nudge "go with approach 2 from the description"
  """

  def run(argv) do
    {opts, rest, _} =
      OptionParser.parse(argv,
        strict: [
          plan: :string,
          max_steps: :integer,
          scenario: :string,
          jira: :string,
          force: :boolean,
          budget: :float,
          model: :string,
          visual: :boolean,
          nudge: :string
        ],
        aliases: [
          p: :plan,
          s: :max_steps,
          S: :scenario,
          j: :jira,
          f: :force,
          b: :budget,
          m: :model,
          v: :visual,
          n: :nudge
        ]
      )

    Application.ensure_all_started(:golem)

    for id <- :logger.get_handler_ids(), id != :golem_file do
      :logger.set_handler_config(id, :level, :none)
    end

    if model = opts[:model] do
      Application.put_env(:golem, :planner_model, model)
      Application.put_env(:golem, :executor_model, model)
    end

    if opts[:jira] do
      run_jira(opts[:jira], opts)
    else
      run_standard(opts, rest)
    end
  end

  defp run_jira(ticket_key, opts) do
    if opts[:budget], do: Application.put_env(:golem, :max_cost, opts[:budget])

    runner_opts =
      (case opts[:max_steps] do
        nil -> []
        n -> [max_steps: n]
      end) ++
        (if opts[:force], do: [skip_eval: true], else: []) ++
        (if opts[:visual], do: [visual_verify: true], else: []) ++
        (case opts[:nudge] do
          nil -> []
          "" -> []
          text -> [nudge: text]
        end)

    case Golem.Jira.Integration.run(ticket_key, runner_opts) do
      {:ok, _} -> :ok
      {:error, :max_steps_reached} -> :ok
      {:error, reason} -> IO.puts(:stderr, "\n✗ #{format_error(reason)}")
    end
  end

  defp run_standard(opts, rest) do
    if opts[:budget], do: Application.put_env(:golem, :max_cost, opts[:budget])

    goal =
      case opts[:scenario] do
        nil ->
          Enum.join(rest, " ")

        name ->
          path = Path.join("scenarios", "#{name}.md")

          case File.read(path) do
            {:ok, content} ->
              extract_goal(content)

            {:error, _} ->
              IO.puts(:stderr, "Scenario not found: #{path}")
              IO.puts(:stderr, "Available: #{list_scenarios()}")
              exit({:shutdown, 1})
          end
      end

    if goal == "" do
      IO.puts(:stderr, "Usage: golem run \"your goal here\"")
      IO.puts(:stderr, "       golem run --scenario smoke_maze")
      IO.puts(:stderr, "       golem run --jira SA-1111")
      exit({:shutdown, 1})
    end

    goal =
      case opts[:nudge] do
        nil -> goal
        "" -> goal
        text -> "## Operator note\n\n#{text}\n\n#{goal}"
      end

    runner_opts =
      case opts[:plan] do
        nil ->
          []

        path ->
          case File.read(path) do
            {:ok, plan} ->
              [plan: plan]

            {:error, reason} ->
              IO.puts(:stderr, "Failed to read plan file #{path}: #{inspect(reason)}")
              exit({:shutdown, 1})
          end
      end

    runner_opts =
      case opts[:max_steps] do
        nil -> runner_opts
        n -> Keyword.put(runner_opts, :max_steps, n)
      end

    case Golem.run(goal, runner_opts) do
      {:ok, _} -> :ok
      {:error, :max_steps_reached} -> :ok
      {:error, reason} -> IO.puts(:stderr, "\n✗ #{format_error(reason)}")
    end
  end

  defp extract_goal(content) do
    case Regex.run(~r/## Goal\s*\n(.*)/s, content) do
      [_, goal] -> String.trim(goal)
      nil -> String.trim(content)
    end
  end

  defp format_error(:planner_max_steps),
    do: "Planner hit max exploration steps — increase :planner_max_steps config"

  defp format_error(:ticket_rejected), do: "Ticket was rejected by evaluator"
  defp format_error(:budget_exceeded), do: "Cost budget exceeded"

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
