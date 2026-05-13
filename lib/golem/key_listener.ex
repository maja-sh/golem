defmodule Golem.KeyListener do
  @moduledoc """
  Reads single keystrokes from stdin and dispatches them to the rest
  of the system. Started by `Golem.TUI` as part of `init_display`.

  Today the only binding is **`p`** which toggles `Golem.TUI` pause
  state. The runner checks that flag between turns and waits if set.

  ## How it works

  On boot the terminal is switched into a near-raw mode
  (`stty -icanon -echo min 1 time 0`) so individual keypresses are
  delivered immediately without waiting for Enter. The original `stty`
  settings are captured first and restored on terminate/2 + a belt-
  and-braces `System.at_exit/1` so a crash doesn't leave the shell in
  a broken state.

  ## Caveats

    * Runs only on Unix-like systems (depends on `/bin/stty`).
    * `IO.gets/1` does not work while this listener is active — line
      buffering is off. The TUI's `confirm_continue` prompt (used only
      at step/budget caps) will misbehave; use Ctrl-C to bail in that
      situation.
    * Pause granularity is one agent turn — pressing `p` mid-API-call
      doesn't interrupt the call. The pause takes effect at the start
      of the next turn.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    case capture_and_set_raw() do
      {:ok, orig_stty} ->
        parent = self()
        {:ok, reader} = Task.start_link(fn -> reader_loop(parent) end)

        # Belt-and-braces: at_exit still fires when terminate/2 doesn't
        # (BEAM hard halt, brutal_kill shutdown).
        System.at_exit(fn _ -> restore_stty(orig_stty) end)

        {:ok, %{orig_stty: orig_stty, reader: reader}}

      :error ->
        # No TTY / stty unavailable. Stay alive but inert so callers
        # don't have to special-case our absence.
        Logger.debug("KeyListener: no TTY available, keybindings disabled")
        {:ok, %{orig_stty: nil, reader: nil}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.orig_stty, do: restore_stty(state.orig_stty)
    :ok
  end

  @impl true
  def handle_info({:key, ?p}, state) do
    Golem.TUI.toggle_pause()
    {:noreply, state}
  end

  # Ignore everything else — Ctrl-C still signals via SIGINT because
  # we left isig enabled in our stty incantation.
  def handle_info({:key, _}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  # --- Private ---

  defp capture_and_set_raw do
    case System.cmd("stty", ["-g"], stderr_to_stdout: true) do
      {orig, 0} ->
        orig = String.trim(orig)

        case System.cmd("stty", ["-icanon", "-echo", "min", "1", "time", "0"],
               stderr_to_stdout: true
             ) do
          {_, 0} -> {:ok, orig}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp restore_stty(orig) do
    System.cmd("stty", [orig], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp reader_loop(parent) do
    case IO.binread(:stdio, 1) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      <<c>> ->
        send(parent, {:key, c})
        reader_loop(parent)

      _ ->
        reader_loop(parent)
    end
  end
end
