defmodule Penbot.TUI do
  @moduledoc """
  Terminal UI matching Claude Code's output style.

  Scrolling output shows agent thoughts, collapsed tool calls with
  timing/token info, and sub-agent trees. Status bar at bottom shows
  progress bar and checklist items.
  """

  require Logger

  @state_key :penbot_tui_state

  # --- Lifecycle ---

  def init(run_id, goal) do
    Application.ensure_all_started(:owl)

    :persistent_term.put(@state_key, %{
      step: 0, max_steps: 0, cost: "$0.0000", progress: [], action: nil
    })

    Logger.configure(level: :warning)

    goal_short = trunc_text(goal, 90)
    puts([
      Owl.Data.tag("● ", :cyan),
      Owl.Data.tag("Forge ", [:bright, :white]),
      Owl.Data.tag(run_id, :faint)
    ])
    puts([Owl.Data.tag("  #{goal_short}", :faint)])
    puts("")

    Owl.LiveScreen.add_block(:statusbar,
      state: %{step: 0, max_steps: 0, cost: "$0.0000", progress: [], action: nil},
      render: &render_statusbar/1
    )
  end

  def stop do
    try do
      Owl.LiveScreen.flush()
    catch
      :exit, _ -> :ok
    end
    Logger.configure(level: :info)
  end

  # --- Planning ---

  def planning(label \\ "Planning...") do
    puts([Owl.Data.tag("+ ", :yellow), Owl.Data.tag(label, :yellow)])
  end

  def plan_created(plan) do
    phases = Regex.scan(~r/^## /m, plan) |> length()
    steps = Regex.scan(~r/- \[ \]/m, plan) |> length()
    puts([
      Owl.Data.tag("✓ ", :green),
      Owl.Data.tag("Plan created ", :green),
      Owl.Data.tag("(#{phases} phases, #{steps} steps)", :faint)
    ])
    puts("")
  end

  # --- Steps ---

  def step_header(step, max_steps, cost_str) do
    update_state(%{step: step, max_steps: max_steps, cost: cost_str, action: nil})
  end

  def agent_text(nil), do: :ok
  def agent_text(text) do
    puts([
      Owl.Data.tag("● ", :cyan),
      Owl.Data.tag(trunc_text(text, 120), :white)
    ])
  end

  # --- Tool Calls ---

  def tool_call(name, detail) do
    update_state(%{action: "#{name} #{detail}"})
  end

  def tool_result(name, detail, result, elapsed_ms, tokens) do
    elapsed = format_elapsed(elapsed_ms)
    tok = format_tokens(tokens)

    # Format result summary
    result_summary = result_oneliner(result)

    puts([
      Owl.Data.tag("  #{tool_icon(name)} ", :faint),
      Owl.Data.tag(tool_label(name, detail), :white),
      Owl.Data.tag(" (#{elapsed}", :faint),
      if(tok != "", do: Owl.Data.tag(" · #{tok}", :faint), else: ""),
      Owl.Data.tag(")", :faint)
    ])

    if result_summary != "" do
      puts([Owl.Data.tag("  └ #{result_summary}", :faint)])
    end
  end

  def tool_error(name, detail, error_text) do
    puts([
      Owl.Data.tag("  ✗ ", :red),
      Owl.Data.tag(tool_label(name, detail), :red),
    ])
    puts([Owl.Data.tag("  └ #{trunc_text(error_text, 100)}", [:faint, :red])])
  end

  # --- Sub-agents ---

  def sub_agent_start(goal) do
    puts([
      Owl.Data.tag("  ● ", :magenta),
      Owl.Data.tag("Running sub-agent...", :magenta)
    ])
    puts([Owl.Data.tag("  │ #{trunc_text(goal, 90)}", :faint)])
  end

  def sub_agent_result(goal, steps, success) do
    icon = if success, do: "✓", else: "✗"
    color = if success, do: :green, else: :red
    puts([
      Owl.Data.tag("  #{icon} ", color),
      Owl.Data.tag("Sub-agent ", color),
      Owl.Data.tag("· #{steps} steps · ", :faint),
      Owl.Data.tag(trunc_text(goal, 60), :faint)
    ])
  end

  # --- Replan ---

  def replan_start do
    puts([
      Owl.Data.tag("+ ", :yellow),
      Owl.Data.tag("Re-planning with Opus...", :yellow)
    ])
  end

  def replan_done do
    puts([
      Owl.Data.tag("✓ ", :green),
      Owl.Data.tag("Plan revised", :green)
    ])
  end

  # --- Completion ---

  def run_complete(success, summary) do
    update_state(%{action: nil})
    puts("")
    if success do
      puts([Owl.Data.tag("✓ ", :green), Owl.Data.tag("Goal achieved", [:bright, :green])])
    else
      puts([Owl.Data.tag("✗ ", :red), Owl.Data.tag("Goal not achieved", [:bright, :red])])
    end
    puts([Owl.Data.tag("  #{trunc_text(summary, 120)}", :faint)])
  end

  def run_paused(run_id) do
    puts("")
    puts([
      Owl.Data.tag("⏸ ", :yellow),
      Owl.Data.tag("Paused ", :yellow),
      Owl.Data.tag("— resume: ", :faint),
      Owl.Data.tag("mix penbot.resume #{run_id}", :white)
    ])
  end

  def run_error(reason) do
    puts("")
    puts([Owl.Data.tag("✗ Error: #{inspect(reason)}", :red)])
  end

  # --- Progress ---

  def set_progress(items) do
    # Print progress items as scrolling output
    completed = Enum.count(items, &(&1.status == :completed))
    total = length(items)

    Enum.each(items, fn item ->
      {icon, color} = case item.status do
        :completed -> {"✓", :green}
        :in_progress -> {"→", :yellow}
        :pending -> {"·", :faint}
      end
      style = if item.status == :pending, do: :faint, else: :white
      puts([
        Owl.Data.tag("  [", :faint),
        Owl.Data.tag(icon, color),
        Owl.Data.tag("] ", :faint),
        Owl.Data.tag(trunc_text(item.text, 60), style)
      ])
    end)

    puts([Owl.Data.tag("  (#{completed}/#{total})", :faint)])
  end

  # --- Status Bar Renderer ---

  defp render_statusbar(%{step: step, max_steps: max, cost: cost, action: action}) do
    bar_width = 20
    pct = if max > 0, do: min(step / max, 1.0), else: 0
    filled = round(pct * bar_width)
    empty = bar_width - filled

    line = [
      Owl.Data.tag(String.duplicate("█", filled), :green),
      Owl.Data.tag(String.duplicate("░", empty), :faint),
      " ",
      Owl.Data.tag("#{step}/#{max}", :white),
      Owl.Data.tag(" │ ", :faint),
      Owl.Data.tag(cost, :yellow)
    ]

    if action do
      line ++ [Owl.Data.tag(" │ ", :faint), Owl.Data.tag("⠋ #{trunc_text(action, 40)}", :magenta)]
    else
      line
    end
  end

  # Catch-all for any extra keys in state
  defp render_statusbar(state) do
    render_statusbar(Map.take(state, [:step, :max_steps, :cost, :action]))
  end

  # --- Helpers ---

  defp update_state(changes) do
    current = :persistent_term.get(@state_key, %{
      step: 0, max_steps: 0, cost: "$0.0000", progress: [], action: nil
    })
    new_state = Map.merge(current, changes)
    :persistent_term.put(@state_key, new_state)
    Owl.LiveScreen.update(:statusbar, new_state)
  end

  defp puts(data), do: Owl.IO.puts(data)

  defp trunc_text(text, max) when is_binary(text) do
    if String.length(text) > max, do: String.slice(text, 0, max - 3) <> "...", else: text
  end
  defp trunc_text(_, _), do: ""

  def format_elapsed(nil), do: "..."
  def format_elapsed(ms) when ms < 1000, do: "#{ms}ms"
  def format_elapsed(ms), do: "#{Float.round(ms / 1000, 1)}s"

  def format_tokens(nil), do: ""
  def format_tokens(0), do: ""
  def format_tokens(n) when n < 1000, do: "#{n} tokens"
  def format_tokens(n), do: "#{Float.round(n / 1000, 1)}k tokens"

  defp tool_icon("shell"), do: "$"
  defp tool_icon("write_file"), do: "+"
  defp tool_icon("read_file"), do: "↓"
  defp tool_icon("edit_file"), do: "~"
  defp tool_icon("glob"), do: "⌕"
  defp tool_icon("grep"), do: "⌕"
  defp tool_icon("web_search"), do: "🔍"
  defp tool_icon("web_fetch"), do: "↓"
  defp tool_icon("screenshot"), do: "📷"
  defp tool_icon("think"), do: "💭"
  defp tool_icon("update_progress"), do: "📋"
  defp tool_icon("done"), do: "✓"
  defp tool_icon("sub_agent"), do: "●"
  defp tool_icon("ask_user"), do: "?"
  defp tool_icon(_), do: "▶"

  defp tool_label("shell", cmd), do: "Shell · #{trunc_text(cmd, 60)}"
  defp tool_label("write_file", path), do: "Write #{path}"
  defp tool_label("read_file", path), do: "Read #{path}"
  defp tool_label("edit_file", path), do: "Edit #{path}"
  defp tool_label("glob", pattern), do: "Glob #{pattern}"
  defp tool_label("grep", pattern), do: "Grep #{pattern}"
  defp tool_label("web_search", query), do: "Search · #{trunc_text(query, 60)}"
  defp tool_label("web_fetch", url), do: "Fetch #{trunc_text(url, 60)}"
  defp tool_label("list_directory", path), do: "List #{path}"
  defp tool_label("sub_agent", goal), do: "Sub-agent · #{trunc_text(goal, 50)}"
  defp tool_label("update_progress", _), do: "Progress update"
  defp tool_label("done", _), do: "Done"
  defp tool_label("think", _), do: "Thinking..."
  defp tool_label("ask_user", _), do: "Asking user..."
  defp tool_label(name, _), do: name

  defp result_oneliner(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> List.first("")
    |> trunc_text(90)
  end
  defp result_oneliner(_), do: ""
end
