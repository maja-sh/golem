defmodule PinnedStatus do
  @moduledoc """
  A pinned status block at the bottom of the terminal, diff-rendered.

  The block stays anchored at the bottom while other output scrolls
  above it (via `println/1`). Each call to `set_status/1` diffs the new
  lines against what's currently on screen and only rewrites lines
  that actually changed — unchanged lines emit a single cursor-down
  byte, which prevents the flicker and scrollback noise typical of
  "erase the whole block, redraw it" implementations.

  ## Output device

  By default writes go to `:stdio`. Pass `io: pid` to `start_link/1` to
  redirect somewhere else — most useful in tests where you want to
  inspect the emitted byte stream:

      {:ok, io} = StringIO.open("")
      {:ok, _}  = PinnedStatus.start_link(io: io, name: :test_ps)
      PinnedStatus.set_status(["one", "two"], name: :test_ps)
      {_, written} = StringIO.contents(io)
  """

  use GenServer

  @type line :: IO.chardata()

  # --- Public API ---

  @doc """
  Start the GenServer.

  ## Options

  * `:io` — IO device to write to. Defaults to `:stdio`.
  * `:name` — registered name. Defaults to `PinnedStatus`.
  * `:hide_cursor` — emit cursor-hide on start, cursor-show on stop.
    Defaults to `true`. Set to `false` for tests so the byte stream is
    just the diff output.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Replace the pinned status block with `lines`. Each element is one
  line; iodata is allowed (will be flattened to a string). Lines that
  are byte-identical to the previously rendered version emit no
  content — just a cursor-down move.

  Callers are responsible for keeping each line within the terminal
  width; longer lines will wrap and break the row math. See
  `PinnedStatus.ANSI.truncate_visible/2` for a helper.
  """
  @spec set_status([line()], keyword()) :: :ok
  def set_status(lines, opts \\ []) when is_list(lines) do
    GenServer.call(server(opts), {:set_status, normalize(lines)})
  end

  @doc """
  Print `content` to the scroll buffer above the pinned block.
  `content` may include newlines or be iodata. The pinned block is
  briefly erased and redrawn around the print so it stays at the
  bottom.
  """
  @spec println(line(), keyword()) :: :ok
  def println(content, opts \\ []) do
    GenServer.call(server(opts), {:println, IO.chardata_to_string(content)})
  end

  @doc """
  Erase the pinned block, run `fun` (in the caller's process), then
  redraw. Use this to wrap blocking input or anything that prints to
  stdout/stderr outside the pinned-status protocol — without it, the
  caller's output would intermix with our redraws.
  """
  @spec pause((-> term()), keyword()) :: term()
  def pause(fun, opts \\ []) when is_function(fun, 0) do
    server = server(opts)
    saved = GenServer.call(server, :detach)

    try do
      fun.()
    after
      GenServer.call(server, {:reattach, saved})
    end
  end

  @doc """
  Erase the pinned block and stop the GenServer.
  """
  @spec stop(keyword()) :: :ok
  def stop(opts \\ []) do
    GenServer.call(server(opts), :stop_and_shutdown)
  end

  @doc """
  Returns the lines currently on screen, as the library believes them
  to be. Useful in tests for asserting visible state without parsing
  the byte stream.
  """
  @spec current(keyword()) :: [String.t()]
  def current(opts \\ []) do
    GenServer.call(server(opts), :current)
  end

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)

  defp normalize(lines) do
    Enum.map(lines, fn line ->
      line
      |> IO.chardata_to_string()
      |> String.replace("\n", " ")
    end)
  end

  # --- GenServer ---

  @impl true
  def init(opts) do
    # Trap exits so terminate/2 runs when the parent process dies —
    # without it, the cursor stays hidden after a crash because we
    # never get a chance to emit `\e[?25h`.
    Process.flag(:trap_exit, true)

    io = Keyword.get(opts, :io, :stdio)
    hide_cursor = Keyword.get(opts, :hide_cursor, true)

    if hide_cursor do
      IO.write(io, "\e[?25l")

      # Belt-and-braces: register a System.at_exit handler so the
      # cursor is restored even when terminate/2 doesn't run (BEAM
      # hard halt, brutal_kill shutdown, etc.). Writes directly to
      # :stdio rather than `io` because by the time at_exit fires the
      # captured StringIO pid (used by tests) may already be gone.
      System.at_exit(fn _status -> IO.write("\e[?25h") end)
    end

    {:ok, %{io: io, current: [], hide_cursor: hide_cursor, attached: true}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.hide_cursor, do: IO.write(state.io, "\e[?25h")
    :ok
  end

  @impl true
  def handle_call({:set_status, new}, _from, state) do
    {state, io_data} = render_diff(state, new)
    IO.write(state.io, io_data)
    {:reply, :ok, state}
  end

  def handle_call({:println, text}, _from, state) do
    saved = state.current
    {state, wipe} = erase(state)
    body = [text, ?\n]
    {state, redraw} = render_diff(state, saved)
    IO.write(state.io, [wipe, body, redraw])
    {:reply, :ok, state}
  end

  def handle_call(:detach, _from, state) do
    saved = state.current
    {state, wipe} = erase(state)
    if state.hide_cursor, do: IO.write(state.io, [wipe, "\e[?25h"]), else: IO.write(state.io, wipe)
    {:reply, saved, %{state | attached: false}}
  end

  def handle_call({:reattach, saved}, _from, state) do
    if state.hide_cursor, do: IO.write(state.io, "\e[?25l")
    {state, io_data} = render_diff(%{state | attached: true}, saved)
    IO.write(state.io, io_data)
    {:reply, :ok, state}
  end

  def handle_call(:current, _from, state), do: {:reply, state.current, state}

  def handle_call(:stop_and_shutdown, _from, state) do
    {state, wipe} = erase(state)
    cursor = if state.hide_cursor, do: "\e[?25h", else: ""
    IO.write(state.io, [wipe, cursor])
    {:stop, :normal, :ok, state}
  end

  # --- Render ---

  # Build a byte stream that transforms the screen from `state.current`
  # to `new`, then return the updated state. Cursor invariant: on
  # entry, cursor sits on the row *after* the last status line (or
  # wherever it was if status is empty); on exit, the same invariant
  # holds for `new`.
  defp render_diff(state, new) do
    old = state.current

    move_up =
      case length(old) do
        0 -> []
        n -> ["\e[", Integer.to_string(n), "A"]
      end

    body = diff_lines(old, new)

    {%{state | current: new}, [move_up, body]}
  end

  # Walk both lists in parallel, emit:
  #   - same line   -> "\e[1E" (cursor next line)
  #   - new line    -> "\r\e[2K" <line> "\n"
  #   - stale line  -> handled in bulk by the [_|_]/[] clause below
  defp diff_lines([], []), do: []

  defp diff_lines([h | t_old], [h | t_new]) do
    ["\e[1E" | diff_lines(t_old, t_new)]
  end

  defp diff_lines([_ | t_old], [new_h | t_new]) do
    ["\r\e[2K", new_h, ?\n | diff_lines(t_old, t_new)]
  end

  defp diff_lines([], [new_h | t_new]) do
    ["\r\e[2K", new_h, ?\n | diff_lines([], t_new)]
  end

  # Old has lines we no longer want. Don't emit "\r\e[2K\n" per stale
  # line — that clears the row but advances the cursor past it, which
  # leaves the cursor invariant ("on row after last status line")
  # pointing at a row *below* where the new block now ends. Subsequent
  # renders then move_up by the new (smaller) line count and miss the
  # actual top of the block — old content above the cursor never gets
  # cleared, and the next terminal scroll pushes it into scrollback as
  # a ghost snapshot of the bar.
  #
  # Instead, clear from the cursor to the end of the screen in one shot
  # and don't advance. Cursor stays on the row directly after the last
  # new status line, which is exactly what the invariant requires.
  defp diff_lines([_ | _], []) do
    ["\e[J"]
  end

  # Used by println and detach — wipe the on-screen block back to
  # nothing, leaving cursor at column 1 on the row where the status
  # block started.
  defp erase(%{current: []} = state), do: {state, []}

  defp erase(%{current: old} = state) do
    n = length(old)
    # Move up to top of block, clear from there to end of screen.
    wipe = ["\e[", Integer.to_string(n), "A", "\e[J"]
    {%{state | current: []}, wipe}
  end
end
