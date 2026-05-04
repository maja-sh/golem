defmodule Mix.Tasks.Golem.Mcp do
  @moduledoc """
  Check MCP server status and list discovered tools.

      mix golem.mcp

  Same implementation as `golem mcp` (release CLI) — see `Golem.CLI.MCP`.
  """
  use Mix.Task

  @shortdoc "Check MCP server status and discovered tools"

  @impl Mix.Task
  def run(args) do
    Golem.CLI.MCP.run(args)
  end
end
