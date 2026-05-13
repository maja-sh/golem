defmodule PinnedStatus.ScenarioTest do
  use ExUnit.Case, async: false

  alias PinnedStatus.Scenario

  setup do
    {:ok, io} = StringIO.open("")
    name = :"ps_scen_#{System.unique_integer([:positive])}"
    {:ok, _} = PinnedStatus.start_link(io: io, hide_cursor: false, name: name)

    on_exit(fn ->
      try do
        if Process.whereis(name), do: PinnedStatus.stop(name: name)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, io: io, name: name}
  end

  defp slice(io, from, to) when is_integer(from) and is_integer(to) do
    {_, all} = StringIO.contents(io)
    binary_part(all, from, to - from)
  end

  test "checklist_tick: spinner ticks emit no checklist bytes", %{io: io, name: name} do
    steps = Scenario.load("test/scenarios/checklist_tick.exs")
    {:ok, marks} = Scenario.play(name, steps, io: io)

    {_, all} = StringIO.contents(io)
    after_ticks = byte_size(all)
    delta = slice(io, marks.after_initial, after_ticks)

    refute delta =~ "Bootstrap"
    refute delta =~ "Build"
    refute delta =~ "Ship"

    # All ten spinner frames should appear in the delta.
    for frame <- ~w(⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) do
      assert delta =~ frame, "expected frame #{inspect(frame)} in tick delta"
    end
  end

  test "grow_and_shrink: each pin reaches the screen as expected", %{io: io, name: name} do
    steps = Scenario.load("test/scenarios/grow_and_shrink.exs")
    {:ok, _marks} = Scenario.play(name, steps, io: io)

    # After the full sequence we should be back to a single line.
    assert PinnedStatus.current(name: name) == ["one"]

    # The byte stream must contain "five" somewhere (the peak).
    {_, all} = StringIO.contents(io)
    assert all =~ "five"
  end

  test "scrolling_with_pin: println content lands in scroll buffer above status", %{
    io: io,
    name: name
  } do
    steps = Scenario.load("test/scenarios/scrolling_with_pin.exs")
    {:ok, _marks} = Scenario.play(name, steps, io: io)

    {_, all} = StringIO.contents(io)
    # All three printed lines should be in the output stream.
    assert all =~ "ls /home/agent"
    assert all =~ "Read foo.ex"
    assert all =~ "shell"

    # The pinned status is still 2 lines tall.
    assert length(PinnedStatus.current(name: name)) == 2
  end
end
