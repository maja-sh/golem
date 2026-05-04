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
    "doctor" => {Golem.CLI.Doctor, "Validate config + runtime health"}
  }

  @legacy_mix_tasks ~w(run resume setup iterate config mcp export)

  def main(argv) do
    Application.ensure_all_started(:golem)
    dispatch(argv)
  end

  def dispatch([]), do: print_help()
  def dispatch(["help"]), do: print_help()
  def dispatch(["--help"]), do: print_help()
  def dispatch(["-h"]), do: print_help()

  def dispatch([cmd | rest]) do
    cond do
      Map.has_key?(@subcommands, cmd) ->
        {mod, _} = Map.fetch!(@subcommands, cmd)
        mod.run(rest)

      cmd in @legacy_mix_tasks ->
        IO.puts(:stderr, "`golem #{cmd}` is not yet wired up — use `mix golem.#{cmd}` for now.")
        exit({:shutdown, 2})

      true ->
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

    IO.puts(device, "")
    IO.puts(device, "Other commands are still served via mix tasks: " <> Enum.join(Enum.map(@legacy_mix_tasks, &"mix golem.#{&1}"), ", "))
  end
end
