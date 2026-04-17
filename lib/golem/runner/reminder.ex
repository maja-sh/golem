defmodule Golem.Runner.Reminder do
  @moduledoc """
  Builds the per-turn `<system-reminder>` message appended before each
  API call. Contains step/budget/progress/recent-commands — rebuilt
  fresh every turn so the agent sees current runtime state without
  bloating conversation history.

  Pure function: given state + progress + budget, returns a string.
  The runner is responsible for reading progress from
  `:persistent_term` and config from `Application.get_env`.
  """

  alias Golem.Runner.Compaction

  @doc """
  Build a `<system-reminder>` user message payload.

  `opts` keys:

    * `:step`       — integer
    * `:max_steps`  — integer
    * `:cost`       — float, dollars spent so far
    * `:budget`     — float, dollar budget (0 for "no budget")
    * `:progress`   — list of `%{text: _, status: _}` maps (status atom)
    * `:history`    — list of `{tool, input, result}` tuples
    * `:recent_n`   — how many recent commands to include (default 5)
  """
  def build(opts) do
    step = Keyword.fetch!(opts, :step)
    max_steps = Keyword.fetch!(opts, :max_steps)
    cost = Keyword.get(opts, :cost, 0.0)
    budget = Keyword.get(opts, :budget, 0.0)
    progress = Keyword.get(opts, :progress, [])
    history = Keyword.get(opts, :history, [])
    recent_n = Keyword.get(opts, :recent_n, 5)

    budget_pct = if budget > 0, do: round(cost / budget * 100), else: 0

    progress_line = format_progress_line(progress)
    recent_commands = format_recent_commands(history, recent_n)

    """
    <system-reminder>
    Runtime context (system state, not user instruction):

    - Step #{step}/#{max_steps} · Cost $#{:erlang.float_to_binary(cost, decimals: 2)} / $#{:erlang.float_to_binary(budget, decimals: 2)} (#{budget_pct}% budget used)#{progress_line}#{recent_commands}

    Use this to avoid repeating failed actions. If recent commands show a pattern (repeated failures, OOMs, stalls), pick a different approach — do not retry the same thing.
    </system-reminder>\
    """
  end

  @doc """
  Summary line for the progress checklist, e.g.:

      \n- Progress: 7/8 done · active: "Commit changes"

  Returns "" when progress is empty.
  """
  def format_progress_line([]), do: ""

  def format_progress_line(items) do
    done = Enum.count(items, &(&1.status in [:completed, :done]))
    total = length(items)
    active = Enum.find(items, &(&1.status == :in_progress))

    active_part =
      if active,
        do: ~s{ · active: "#{Compaction.truncate_str(active.text, 40)}"},
        else: ""

    "\n- Progress: #{done}/#{total} done#{active_part}"
  end

  @doc """
  Render the last `limit` history entries as a bulleted list with
  status suffixes. Returns "" when history is empty.
  """
  def format_recent_commands(history, limit) do
    recent = Enum.take(history, -limit)

    if recent == [] do
      ""
    else
      lines =
        Enum.map_join(recent, "\n", fn {tool, input, result} ->
          input_str = Compaction.truncate_str(to_string(input), 60)
          status = short_status(result)
          "  - [#{tool}] #{input_str}#{status}"
        end)

      "\n- Recent tool calls:\n#{lines}"
    end
  end

  @doc """
  Short status hint derived from a tool_result body. Examples:
  `" → exit 137"`, `" → timed out"`, `" → stalled"`, `" → error"`.
  Empty string when there's nothing useful to report.
  """
  def short_status(result) when is_binary(result) do
    cond do
      String.starts_with?(result, "[exit code ") ->
        case Regex.run(~r/^\[exit code (\d+)\]/, result) do
          [_, code] -> " → exit #{code}"
          _ -> " → failed"
        end

      String.starts_with?(result, "[command timed out]") ->
        " → timed out"

      String.starts_with?(result, "[command stalled") ->
        " → stalled"

      String.starts_with?(result, "[error]") ->
        " → error"

      true ->
        ""
    end
  end

  def short_status(_), do: ""
end
