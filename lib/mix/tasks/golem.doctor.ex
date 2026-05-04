defmodule Mix.Tasks.Golem.Doctor do
  @moduledoc """
  Validate Golem's configuration and runtime environment.

      mix golem.doctor

  Same implementation as `golem doctor` (release CLI) — see `Golem.CLI.Doctor`.
  """
  use Mix.Task

  @shortdoc "Validate Golem config + runtime"

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:golem)
    Golem.CLI.Doctor.run(args)
  end
end
