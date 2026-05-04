defmodule Mix.Tasks.Golem.Resume do
  @moduledoc """
  Resume a paused run.

      mix golem.resume <run_id>
      mix golem.resume <run_id> --max-steps 200
      mix golem.resume <run_id> --budget 30
      mix golem.resume <run_id> --message "also handle the fallback case"
      mix golem.resume --list

  Same implementation as `golem resume` (release CLI) — see `Golem.CLI.Resume`.
  """

  use Mix.Task

  @shortdoc "Resume a paused run"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Golem.CLI.Resume.run(args)
  end
end
