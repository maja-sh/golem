defmodule Mix.Tasks.Golem.Export do
  @moduledoc """
  Export files from the container to local filesystem.

      mix golem.export <container_path> [local_path]

  Same implementation as `golem export` (release CLI) — see `Golem.CLI.Export`.
  """
  use Mix.Task

  @shortdoc "Export files from the container"

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:golem)
    Golem.CLI.Export.run(args)
  end
end
