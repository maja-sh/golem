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
    tools = Golem.MCP.tools()

    if status == [] do
      IO.puts("No MCP servers configured.")
      IO.puts("Create .golem/mcp.yml to add servers. See README for config format.")
      return_status(status)
    end

    # Handle config-level errors
    config_errors = Enum.filter(status, &match?({:error, _}, &1))
    for {:error, reason} <- config_errors do
      IO.puts(IO.ANSI.format([:red, "✗ Config error: ", :reset, reason]))
    end

    # Handle per-server status
    server_status = Enum.reject(status, &match?({:error, _}, &1))

    for entry <- server_status do
      case entry do
        {:ok, name, tool_count} ->
          IO.puts(IO.ANSI.format([:green, "✓ #{name}", :reset, :faint, " — #{tool_count} tools", :reset]))

          server_tools =
            tools
            |> Enum.filter(fn t -> String.starts_with?(t.name, "mcp_#{name}_") end)
            |> Enum.sort_by(& &1.name)

          for tool <- server_tools do
            desc = tool.description |> String.replace("[#{name}] ", "") |> String.slice(0, 70)
            IO.puts(IO.ANSI.format([:faint, "  #{tool.name}", :reset]))
            IO.puts(IO.ANSI.format([:faint, "    #{desc}", :reset]))
          end

        {:error, name, reason} ->
          IO.puts(IO.ANSI.format([:red, "✗ #{name}", :reset, :faint, " — #{reason}", :reset]))
      end

      IO.puts("")
    end

    return_status(status)
  end

  defp return_status(status) do
    if Enum.any?(status, &match?({:error, _, _}, &1)) or Enum.any?(status, &match?({:error, _}, &1)) do
      exit({:shutdown, 1})
    end
  end
end
