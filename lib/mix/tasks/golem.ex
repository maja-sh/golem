defmodule Mix.Tasks.Golem do
  @moduledoc """
  Subcommand entry for golem — `mix golem <cmd> [args]` is equivalent to
  `mix golem.<cmd> [args]`. Both forms work; this one matches the `golem`
  binary's syntax for muscle-memory consistency.

      mix golem doctor
      mix golem run --jira PROJ-123
      mix golem iterate
      mix golem                       # prints help

  Same dispatch table as `Golem.CLI`.
  """
  use Mix.Task

  @shortdoc "Run a golem subcommand (mix golem <cmd>)"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    Golem.CLI.dispatch(args)
  end
end
