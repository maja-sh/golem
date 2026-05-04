defmodule Mix.Tasks.Golem.Config do
  @moduledoc """
  Print the resolved Golem configuration.

      mix golem.config

  Same implementation as `golem config` (release CLI) — see `Golem.CLI.Config`.
  """
  use Mix.Task

  @shortdoc "Print resolved Golem configuration"

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:golem)
    Golem.CLI.Config.run(args)
  end
end
