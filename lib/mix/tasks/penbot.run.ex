defmodule Mix.Tasks.Penbot.Run do
  @moduledoc """
  Run the autonomous agent with a goal.

  ## Usage

      mix penbot.run "Build a web scraper in Python"
      mix penbot.run --plan plan.md "Build a web scraper in Python"
      mix penbot.run --max-steps 50 "Set up a Phoenix project"
  """

  use Mix.Task

  @shortdoc "Run the autonomous agent with a goal"

  @impl true
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [plan: :string, max_steps: :integer],
        aliases: [p: :plan, s: :max_steps]
      )

    goal = Enum.join(rest, " ")

    if goal == "" do
      Mix.shell().error("Usage: mix penbot.run \"your goal here\"")
      exit({:shutdown, 1})
    end

    # Start the application
    Mix.Task.run("app.start")

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

    Mix.shell().info("Goal: #{goal}")
    Mix.shell().info("Starting autonomous agent...\n")

    case Penbot.run(goal, runner_opts) do
      {:ok, %{success: true, summary: summary}} ->
        Mix.shell().info("\n✓ Goal achieved: #{summary}")

      {:ok, %{success: false, summary: summary}} ->
        Mix.shell().info("\n✗ Goal not achieved: #{summary}")

      {:error, :max_steps_reached} ->
        Mix.shell().error("\n✗ Hit maximum step limit")

      {:error, reason} ->
        Mix.shell().error("\n✗ Error: #{inspect(reason)}")
    end
  end
end
