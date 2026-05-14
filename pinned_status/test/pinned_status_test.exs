defmodule PinnedStatusTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, io} = StringIO.open("")
    name = :"ps_#{System.unique_integer([:positive])}"
    {:ok, _pid} = PinnedStatus.start_link(io: io, hide_cursor: false, name: name)
    on_exit(fn ->
      try do
        if Process.whereis(name), do: PinnedStatus.stop(name: name)
      catch
        :exit, _ -> :ok
      end
    end)
    {:ok, io: io, name: name}
  end

  defp written(io) do
    {_, out} = StringIO.contents(io)
    out
  end

  defp written_since(io, mark_bytes) when is_integer(mark_bytes) do
    full = written(io)
    binary_part(full, mark_bytes, byte_size(full) - mark_bytes)
  end

  describe "set_status (initial draw)" do
    test "writes each line followed by a newline", %{io: io, name: name} do
      PinnedStatus.set_status(["alpha", "beta"], name: name)
      out = written(io)

      assert out =~ "alpha"
      assert out =~ "beta"
      # Two newlines for two lines.
      assert out |> String.graphemes() |> Enum.count(&(&1 == "\n")) == 2
    end

    test "remembers the rendered lines as `current`", %{io: _io, name: name} do
      PinnedStatus.set_status(["a", "b", "c"], name: name)
      assert PinnedStatus.current(name: name) == ["a", "b", "c"]
    end
  end

  describe "set_status (diff)" do
    test "unchanged lines emit no content — just cursor moves", %{io: io, name: name} do
      PinnedStatus.set_status(["alpha", "beta", "gamma"], name: name)
      mark = byte_size(written(io))

      PinnedStatus.set_status(["alpha", "BETA", "gamma"], name: name)
      delta = written_since(io, mark)

      # Only the middle line was rewritten.
      assert delta =~ "BETA"
      refute delta =~ "alpha"
      refute delta =~ "gamma"
    end

    test "unchanged trailing line emits cursor-next-line, not rewrite", %{io: io, name: name} do
      PinnedStatus.set_status(["x", "y"], name: name)
      mark = byte_size(written(io))

      PinnedStatus.set_status(["X", "y"], name: name)
      delta = written_since(io, mark)

      assert delta =~ "X"
      refute delta =~ "y"
      # \e[1E is the "Cursor Next Line" sequence the diff uses for
      # unchanged rows.
      assert delta =~ "\e[1E"
    end

    test "growing the block writes only the new tail lines", %{io: io, name: name} do
      PinnedStatus.set_status(["a", "b"], name: name)
      mark = byte_size(written(io))

      PinnedStatus.set_status(["a", "b", "c"], name: name)
      delta = written_since(io, mark)

      refute delta =~ "a"
      refute delta =~ "b"
      assert delta =~ "c"
    end

    test "shrinking the block clears stale trailing lines", %{io: io, name: name} do
      PinnedStatus.set_status(["a", "b", "c"], name: name)
      mark = byte_size(written(io))

      PinnedStatus.set_status(["a", "b"], name: name)
      delta = written_since(io, mark)

      # Stale tail is cleared in one shot with \e[J (erase to end of
      # screen) rather than per-line \r\e[2K\n — the latter would
      # advance the cursor past the new block's bottom and break the
      # "cursor on row after last status line" invariant.
      assert delta =~ "\e[J"
      refute delta =~ "a"
      refute delta =~ "b"
      refute delta =~ "c"
    end

    test "identical set_status writes only cursor-move bytes", %{io: io, name: name} do
      PinnedStatus.set_status(["a", "b", "c"], name: name)
      mark = byte_size(written(io))

      PinnedStatus.set_status(["a", "b", "c"], name: name)
      delta = written_since(io, mark)

      refute delta =~ "a"
      refute delta =~ "b"
      refute delta =~ "c"
      # Should consist only of move-up + three cursor-next-line moves.
      assert delta =~ "\e[3A"
      assert (delta |> String.split("\e[1E") |> length()) == 4
    end
  end

  describe "println" do
    test "writes the scroll content and restores the status", %{io: io, name: name} do
      PinnedStatus.set_status(["pinned"], name: name)
      mark = byte_size(written(io))

      PinnedStatus.println("scrolled line", name: name)
      delta = written_since(io, mark)

      assert delta =~ "scrolled line"
      # Status was restored — current is unchanged.
      assert PinnedStatus.current(name: name) == ["pinned"]
    end
  end

  describe "pause" do
    test "erases status, runs fn, restores status", %{io: io, name: name} do
      PinnedStatus.set_status(["a", "b"], name: name)
      mark = byte_size(written(io))

      result =
        PinnedStatus.pause(
          fn ->
            assert PinnedStatus.current(name: name) == []
            :returned_value
          end,
          name: name
        )

      assert result == :returned_value
      assert PinnedStatus.current(name: name) == ["a", "b"]

      delta = written_since(io, mark)
      # Erase sequence \e[J should appear (full wipe).
      assert delta =~ "\e[J"
    end
  end

  describe "iodata lines" do
    test "accepts ANSI iodata and flattens to a string", %{io: io, name: name} do
      PinnedStatus.set_status([[IO.ANSI.red(), "boom", IO.ANSI.reset()]], name: name)
      out = written(io)
      assert out =~ "boom"
      assert out =~ "\e[31m"
    end
  end
end
