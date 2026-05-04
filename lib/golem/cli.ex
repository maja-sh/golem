defmodule Golem.CLI do
  @moduledoc """
  Subcommand dispatcher for the `golem` CLI.

  Each subcommand lives in its own module under `Golem.CLI.*` and exposes
  a `run/1` callback that takes argv (the remaining args after the
  subcommand). The same modules back the legacy `mix golem.*` tasks via
  thin shims, so the two entry points share a single implementation.

  Used as the entry point from a release or escript:

      Golem.CLI.main(System.argv())
  """

  @subcommands %{
    "config" => {Golem.CLI.Config, "Print resolved configuration"},
    "doctor" => {Golem.CLI.Doctor, "Validate config + runtime health"},
    "export" => {Golem.CLI.Export, "Export files from the container"},
    "iterate" => {Golem.CLI.Iterate, "Address reviewer feedback on a bot-opened PR"},
    "mcp" => {Golem.CLI.MCP, "Check MCP server status"},
    "resume" => {Golem.CLI.Resume, "Resume a paused run"},
    "run" => {Golem.CLI.Run, "Run the autonomous agent with a goal"},
    "setup" => {Golem.CLI.Setup, "Test project setup (clone repos, run setup scripts)"}
  }

  def main(argv) do
    Application.ensure_all_started(:golem)
    dispatch(argv)
  end

  def dispatch([]), do: print_help()
  def dispatch(["help"]), do: print_help()
  def dispatch(["--help"]), do: print_help()
  def dispatch(["-h"]), do: print_help()

  def dispatch([cmd | rest]) do
    case Map.get(@subcommands, cmd) do
      {mod, _desc} ->
        mod.run(rest)

      nil ->
        IO.puts(:stderr, "Unknown command: #{cmd}")
        IO.puts(:stderr, "")
        print_help(:stderr)
        exit({:shutdown, 1})
    end
  end

  defp print_help(device \\ :stdio) do
    IO.puts(device, "Usage: golem <command> [options]")
    IO.puts(device, "")
    IO.puts(device, "Commands:")

    @subcommands
    |> Enum.sort()
    |> Enum.each(fn {name, {_mod, desc}} ->
      IO.puts(device, "  #{String.pad_trailing(name, 12)}#{desc}")
    end)
  end
end
