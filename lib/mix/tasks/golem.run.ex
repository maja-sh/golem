defmodule Mix.Tasks.Golem.Run do
  @moduledoc """
  Run the autonomous agent with a goal.

      mix golem.run "Build a web scraper in Python"
      mix golem.run --scenario smoke_maze
      mix golem.run --plan plan.md "Build a web scraper in Python"
      mix golem.run --max-steps 50 "Set up a Phoenix project"
      mix golem.run --jira PROJ-123

  Same implementation as `golem run` (release CLI) — see `Golem.CLI.Run`.
  """

  use Mix.Task

  @shortdoc "Run the autonomous agent with a goal"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Golem.CLI.Run.run(args)
  end
end
