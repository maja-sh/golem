defmodule Golem.Runner.Triggers do
  @moduledoc """
  Pure detection logic for the runner's "something is going wrong"
  signals: stuck loops, drift, progress staleness, think loops, large
  files, missing search.

  Each function here is a pure classifier — it takes state/history and
  returns a tagged tuple describing what was detected (if anything).
  The runner is responsible for reading/writing `:persistent_term`,
  logging, and turning the detection into an actual message injection.

  Separating detection from side effects makes the logic testable
  without any GenServer setup or process state.
  """

  # ---- Thresholds ----

  @stuck_edit_threshold 4
  @stuck_shell_threshold 3
  @stuck_repeat_threshold 3
  @max_consecutive_thinks 3
  @file_size_warning_threshold 300
  @progress_stale_signal_threshold 15
  @progress_stale_nudge_threshold 20
  @narrow_tools_min_history 20
  @narrow_tools_max_unique 2
  @error_rate_window 20
  @error_rate_threshold 0.4

  @doc "Exposed for tests and for runner.ex to reuse values."
  def thresholds do
    %{
      stuck_edit: @stuck_edit_threshold,
      stuck_shell: @stuck_shell_threshold,
      stuck_repeat: @stuck_repeat_threshold,
      max_thinks: @max_consecutive_thinks,
      file_size: @file_size_warning_threshold,
      progress_stale_signal: @progress_stale_signal_threshold,
      progress_stale_nudge: @progress_stale_nudge_threshold,
      narrow_tools_min_history: @narrow_tools_min_history,
      narrow_tools_max_unique: @narrow_tools_max_unique,
      error_rate_window: @error_rate_window,
      error_rate_threshold: @error_rate_threshold
    }
  end

  # ---- Stuck detection ----

  @doc """
  Classify the combined history+current executions into one of:

      {:edit_loop, ["file.ex (5 edits)", …]}
      {:shell_loop, ["\\\"npm run build\\\" (3x)", …]}
      {:repeat_loop, count}
      :ok

  `recent_history` is a list of `{tool, input, result}` tuples.
  `executed` is a list of `{%{name: _, input: _}, result}` (what just ran).
  """
  def classify_stuck(recent_history, executed) do
    recent_history = Enum.take(recent_history, -15)

    edit_result = detect_edit_loop(recent_history, executed)

    cond do
      edit_result != :ok ->
        edit_result

      (shell = detect_shell_loop(recent_history, executed)) != :ok ->
        shell

      true ->
        detect_repeat_loop(recent_history, executed)
    end
  end

  defp detect_edit_loop(recent_history, executed) do
    current_edits =
      executed
      |> Enum.filter(fn {tc, _} -> tc.name in ["edit_file", "write_file"] end)
      |> Enum.map(fn {tc, _} -> tc.input["path"] end)
      |> Enum.reject(&is_nil/1)

    recent_edits =
      recent_history
      |> Enum.filter(fn {tool, _, _} -> tool in ["edit_file", "write_file"] end)
      |> Enum.map(fn {_, path, _} -> path end)

    stuck_files =
      (recent_edits ++ current_edits)
      |> Enum.frequencies()
      |> Enum.filter(fn {_, count} -> count >= @stuck_edit_threshold end)
      |> Enum.map(fn {file, count} -> "#{Path.basename(file)} (#{count} edits)" end)

    if stuck_files == [], do: :ok, else: {:edit_loop, stuck_files}
  end

  defp detect_shell_loop(recent_history, executed) do
    recent_shells =
      recent_history
      |> Enum.take(-10)
      |> Enum.filter(fn {tool, _, _} -> tool == "shell" end)
      |> Enum.map(fn {_, input, _} -> String.slice(to_string(input), 0, 100) end)

    current_shells =
      executed
      |> Enum.filter(fn {tc, _} -> tc.name == "shell" end)
      |> Enum.map(fn {tc, _} -> String.slice(to_string(tc.input["command"]), 0, 100) end)

    shell_repeats =
      (recent_shells ++ current_shells)
      |> Enum.frequencies()
      |> Enum.filter(fn {_, count} -> count >= @stuck_shell_threshold end)
      |> Enum.map(fn {cmd, count} -> ~s("#{String.slice(cmd, 0, 60)}...") <> " (#{count}x)" end)

    if shell_repeats == [], do: :ok, else: {:shell_loop, shell_repeats}
  end

  defp detect_repeat_loop(recent_history, executed) do
    # Hash the canonical *summary* on both sides so current and history
    # match each other. Previously current used the raw input map and
    # history used the summary string, so a repeat could only be found
    # entirely within history — and even then `read_file` for different
    # file chunks summarized identically (path-only), which tripped
    # false positives and pinned the executor on Opus via escalation.
    current_sigs =
      Enum.map(executed, fn {tc, _} ->
        "#{tc.name}:#{:erlang.phash2(Golem.Runner.summarize_input(tc))}"
      end)

    recent_sigs =
      Enum.map(recent_history, fn {tool, input, _} ->
        "#{tool}:#{:erlang.phash2(input)}"
      end)

    repeated =
      (recent_sigs ++ current_sigs)
      |> Enum.frequencies()
      |> Enum.filter(fn {_, count} -> count >= @stuck_repeat_threshold end)

    if repeated == [], do: :ok, else: {:repeat_loop, length(repeated)}
  end

  # ---- Think loop ----

  @doc """
  Given the list of tool names just executed and the count of
  preceding think-only turns, return `{:ok, new_count}` or
  `{:think_loop, new_count}` when the threshold is crossed.
  """
  def classify_think_loop(executed_tool_names, previous_consecutive) do
    unique = executed_tool_names |> Enum.uniq()
    think_only = unique == ["think"]
    new_count = if think_only, do: previous_consecutive + 1, else: 0

    if new_count >= @max_consecutive_thinks do
      {:think_loop, new_count}
    else
      {:ok, new_count}
    end
  end

  # ---- Drift heuristics ----

  @doc """
  Cheap signals that suggest the agent may be off-plan. Returns a list
  of atoms (`:stale_progress`, `:narrow_tools`, `:high_error_rate`).
  Empty list means nothing looks off — the caller should skip the
  expensive LLM drift check.

  `opts`:

    * `:step`               — current step number
    * `:history`            — list of `{tool, input, result}` tuples
    * `:last_progress_step` — step at which progress last advanced
  """
  def drift_signals(opts) do
    step = Keyword.fetch!(opts, :step)
    history = Keyword.fetch!(opts, :history)
    last_progress_step = Keyword.get(opts, :last_progress_step, 0)

    []
    |> maybe_add_stale_progress(step, last_progress_step)
    |> maybe_add_narrow_tools(history)
    |> maybe_add_error_rate(history)
  end

  defp maybe_add_stale_progress(signals, step, last_progress_step) do
    if step - last_progress_step >= @progress_stale_signal_threshold,
      do: [:stale_progress | signals],
      else: signals
  end

  defp maybe_add_narrow_tools(signals, history) do
    if length(history) >= @narrow_tools_min_history do
      recent_tools =
        history
        |> Enum.take(-@narrow_tools_min_history)
        |> Enum.map(fn {t, _, _} -> t end)
        |> Enum.uniq()

      if length(recent_tools) <= @narrow_tools_max_unique,
        do: [:narrow_tools | signals],
        else: signals
    else
      signals
    end
  end

  defp maybe_add_error_rate(signals, history) do
    recent = Enum.take(history, -@error_rate_window)

    if length(recent) >= 10 do
      errors =
        Enum.count(recent, fn {_, _, result} ->
          is_binary(result) and String.contains?(result, "[error]")
        end)

      if errors / length(recent) > @error_rate_threshold,
        do: [:high_error_rate | signals],
        else: signals
    else
      signals
    end
  end

  # ---- Staleness nudge ----

  @doc """
  Returns `{:nudge, gap_in_steps}` when the agent hasn't marked
  progress in a while AND we haven't already nudged recently,
  else `:ok`.

  Pure — the caller is responsible for bumping "last nudge step"
  after it injects the nudge.
  """
  def check_staleness(step, last_progress_step, last_nudge_step) do
    gap = step - last_progress_step

    if gap >= @progress_stale_nudge_threshold and
         step - last_nudge_step >= @progress_stale_nudge_threshold do
      {:nudge, gap}
    else
      :ok
    end
  end

  # ---- File size warning ----

  @doc """
  Inspect the executed `write_file` calls for files that went over
  the threshold. Returns list of `{path, line_count}`.
  """
  def oversized_writes(executed) do
    executed
    |> Enum.filter(fn {tc, _} -> tc.name == "write_file" end)
    |> Enum.map(fn {tc, _} ->
      content = Map.get(tc.input, "content", "")
      path = Map.get(tc.input, "path", "")
      lines = content |> String.split("\n") |> length()
      {path, lines}
    end)
    |> Enum.filter(fn {_, lines} -> lines >= @file_size_warning_threshold end)
  end
end
