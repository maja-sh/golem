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
    server_names = read_server_names()

    IO.puts("")
    IO.puts(IO.ANSI.format([:bright, "MCP servers", :reset]))

    if server_names == [] do
      IO.puts(IO.ANSI.format([:faint, "  No servers configured. Create .golem/mcp.yml to add servers.", :reset]))
      IO.puts("")
    else
      # Show all servers as connecting
      for name <- server_names do
        IO.puts(IO.ANSI.format([
          :faint, "  ", :reset, name,
          :faint, " · ", :bright, :yellow, "⋯ connecting", :reset
        ]))
      end

      # Start the app (MCP connects during this)
      Mix.Task.run("app.start")

      for id <- :logger.get_handler_ids(), id != :golem_file do
        :logger.set_handler_config(id, :level, :none)
      end

      Process.sleep(1000)
      status = Golem.MCP.status()

      # Move cursor up and overwrite each line
      IO.write("\e[#{length(server_names)}A")

      for entry <- status do
        IO.write("\e[2K")
        case entry do
          {:ok, name, tool_count} ->
            IO.puts(IO.ANSI.format([
              :faint, "  ", :reset, name,
              :faint, " · ", :bright, :green, "✓ connected", :reset,
              :faint, " · #{tool_count} tools", :reset
            ]))

          {:error, name, reason} ->
            IO.puts(IO.ANSI.format([
              :faint, "  ", :reset, name,
              :faint, " · ", :bright, :red, "✗ #{reason}", :reset
            ]))

          {:error, reason} ->
            IO.puts(IO.ANSI.format([:bright, :red, "  ✗ #{reason}", :reset]))
        end
      end

      IO.puts("")
    end
  end

  defp read_server_names do
    case YamlElixir.read_from_file(".golem/mcp.yml") do
      {:ok, %{"servers" => servers}} when is_list(servers) ->
        Enum.map(servers, fn s -> s["name"] || "unknown" end)
      _ -> []
    end
  end
end
