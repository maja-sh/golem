defmodule Golem.Events do
  @moduledoc """
  Per-run structured event log.

  Every interesting thing that happens during a run (tool calls, API
  calls, sub-agents, compactions, warnings) is appended as one JSON
  object per line to `runs/<run_id>/events.jsonl`. Downstream tools
  can `jq` over the file for post-mortem analysis, replay, or feed
  a live dashboard.

  ## Usage

      # Once, at the start of a run:
      Golem.Events.set_run(run_id)

      # Anywhere in the same process (including sub-agents, which
      # execute inline):
      Golem.Events.emit(:tool_call, %{
        name: "shell",
        input: %{"command" => "ls"},
        step: 12,
        depth: 0
      })

      # At run end:
      Golem.Events.clear_run()

  ## Event shape

      {
        "ts":      "2026-04-17T15:30:12.345Z",
        "type":    "tool_call",
        "step":    12,
        "depth":   0,
        "payload": { ... }
      }

  Top-level fields (`step`, `depth`) are pulled out of `payload` by the
  emitter so `jq` queries like `.step` work without digging.

  The emitter is best-effort — if the file can't be written (disk
  full, permissions) the error is swallowed so it never crashes the
  run. See `emit_or_log/2` for the rescue path.
  """

  require Logger

  @runs_dir "runs"
  @process_key :golem_events_run_id

  @doc "Associate the current process with `run_id`. Subsequent `emit/2` calls write to that run's event log."
  def set_run(run_id) when is_binary(run_id) do
    Process.put(@process_key, run_id)
    :ok
  end

  @doc "Read the run_id bound to the current process (or `nil`)."
  def current_run, do: Process.get(@process_key)

  @doc "Clear the process-bound run_id. Call at run end to prevent stray writes."
  def clear_run do
    Process.delete(@process_key)
    :ok
  end

  @doc """
  Append an event to the current run's `events.jsonl`.

  `type` is an atom like `:tool_call`. `payload` is any JSON-encodable
  map. If `payload` contains `:step` or `:depth`, they're hoisted to
  top-level fields on the entry. If no run_id is bound, the event is
  silently dropped — this lets library code call `emit/2` unguarded
  even from contexts where no run is active (tests, sub-agents
  spawned from REPL, etc.).
  """
  def emit(type, payload \\ %{}) when is_atom(type) and is_map(payload) do
    case current_run() do
      nil -> :ok
      run_id -> emit_to(run_id, type, payload)
    end
  end

  @doc """
  Like `emit/2` but targets a specific run_id. Use for parallel
  sub-agents running in their own process that haven't called
  `set_run/1`.
  """
  def emit_to(run_id, type, payload) when is_binary(run_id) and is_atom(type) and is_map(payload) do
    entry = build_entry(type, payload)
    path = event_path(run_id)

    try do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(entry) <> "\n", [:append])
      :ok
    rescue
      err ->
        # Logged to the file logger (not stdout — TUI doesn't want
        # stray prints). Event-log failures must not sink the run.
        Logger.error("Golem.Events emit failed for #{run_id}: #{Exception.message(err)}")
        :error
    end
  end

  @doc """
  Path to a run's event log. Exposed for tests and downstream tools
  (e.g. `mix golem.events <run_id>` would read from here).
  """
  def event_path(run_id), do: Path.join([@runs_dir, run_id, "events.jsonl"])

  @doc """
  Read all events for a run as a list of maps. Tails the file if
  `tail` is given. Useful for tests and post-mortem tooling.
  """
  def read(run_id, opts \\ []) do
    tail = Keyword.get(opts, :tail)

    case File.read(event_path(run_id)) do
      {:ok, content} ->
        lines = content |> String.split("\n", trim: true)
        lines = if tail, do: Enum.take(lines, -tail), else: lines
        Enum.map(lines, &Jason.decode!/1)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- internals ---

  defp build_entry(type, payload) do
    {step, payload} = Map.pop(payload, :step)
    {depth, payload} = Map.pop(payload, :depth)

    entry = %{
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      type: Atom.to_string(type),
      payload: sanitize(payload)
    }

    entry
    |> maybe_put(:step, step)
    |> maybe_put(:depth, depth)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Jason can't encode tuples, pids, references, or funs. Replace
  # anything dubious with a string. Keeps emission crash-free when a
  # caller accidentally passes a non-JSON value.
  defp sanitize(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, sanitize(v)} end)
  end

  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)
  defp sanitize(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&sanitize/1)
  defp sanitize(value) when is_pid(value) or is_reference(value) or is_function(value) or is_port(value) do
    inspect(value)
  end

  defp sanitize(value), do: value
end
