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

    tools = Golem.MCP.tools()

    if tools == [] do
      IO.puts("No MCP servers configured.")
      IO.puts("Create .golem/mcp.yml to add servers. See README for config format.")
    else
      # Group tools by server
      grouped =
        tools
        |> Enum.group_by(fn tool ->
          case String.split(tool.name, "_", parts: 3) do
            ["mcp", server, _] -> server
            _ -> "unknown"
          end
        end)
        |> Enum.sort()

      for {server, server_tools} <- grouped do
        IO.puts(IO.ANSI.format([:green, "● #{server}", :reset, :faint, " — #{length(server_tools)} tools", :reset]))

        for tool <- Enum.sort_by(server_tools, & &1.name) do
          desc = tool.description |> String.replace("[#{server}] ", "") |> String.slice(0, 70)
          IO.puts(IO.ANSI.format([:faint, "  #{tool.name}", :reset]))
          IO.puts(IO.ANSI.format([:faint, "    #{desc}", :reset]))
        end

        IO.puts("")
      end
    end
  end
end
