defmodule Mix.Tasks.Golem.Mcp do
  @moduledoc """
  Check MCP server status and list discovered tools.

  ## Usage

      mix golem.mcp
  """

  use Mix.Task

  @shortdoc "Check MCP server status and discovered tools"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    # Suppress console logger
    for id <- :logger.get_handler_ids(), id != :golem_file do
      :logger.set_handler_config(id, :level, :none)
    end

    # Give MCP servers a moment to connect
    Process.sleep(2000)

    status = Golem.MCP.status()

    IO.puts("")
    IO.puts(IO.ANSI.format([:bright, "MCP servers", :reset]))

    if status == [] do
      IO.puts(IO.ANSI.format([:faint, "  No servers configured. Create .golem/mcp.yml to add servers.", :reset]))
    else
      for entry <- status do
        case entry do
          {:ok, name, tool_count} ->
            IO.puts(IO.ANSI.format([
              :faint, "  ", :reset,
              name,
              :faint, " · ", :bright, :green, "✓ connected", :reset,
              :faint, " · #{tool_count} tools", :reset
            ]))

          {:error, name, reason} ->
            IO.puts(IO.ANSI.format([
              :faint, "  ", :reset,
              name,
              :faint, " · ", :bright, :red, "✗ #{reason}", :reset
            ]))

          {:error, reason} ->
            IO.puts(IO.ANSI.format([:bright, :red, "  ✗ #{reason}", :reset]))
        end
      end
    end

    IO.puts("")
  end
end
