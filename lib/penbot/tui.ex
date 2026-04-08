defmodule Penbot.TUI do
  @moduledoc """
  Terminal UI using Owl.LiveScreen.

  Scrolling output (thoughts, tool calls, results) is printed sequentially
  via Owl.IO.puts and flows above the sticky status bar.

  The status bar at the bottom shows step count, cost, and progress items.
  """

  require Logger

  @doc """
  Initialize the TUI display. Call once at the start of a run.
  """
  def init(run_id, goal) do
    Application.ensure_all_started(:owl)

    # Suppress console logger — output goes through TUI instead.
    # File logger still captures everything.
    Logger.configure(level: :warning)

    goal_short = truncate_text(goal, 80)

    puts([
      Owl.Data.tag("┌─ Forge ", :cyan),
      Owl.Data.tag(run_id, [:faint, :cyan]),
      Owl.Data.tag(" ─", :cyan)
    ])
    puts([
      Owl.Data.tag("│ ", :cyan),
      Owl.Data.tag(goal_short, :white)
    ])
    puts(Owl.Data.tag("└──────────────────────────────────────", :cyan))
    puts("")

    # Status bar block — stays pinned at the bottom
    Owl.LiveScreen.add_block(:statusbar,
      state: %{step: 0, max_steps: 0, cost: "$0.0000", progress: [], action: nil},
      render: &render_statusbar/1
    )
  end

  @doc """
  Print a step header — called at the start of each step.
  """
  def step_header(step, max_steps, cost_str) do
    Owl.LiveScreen.update(:statusbar, fn state ->
      %{state | step: step, max_steps: max_steps, cost: cost_str, action: nil}
    end)

    puts([
      Owl.Data.tag("── Step #{step}/#{max_steps}", :faint),
      Owl.Data.tag(" │ ", :faint),
      Owl.Data.tag(cost_str, [:faint, :yellow]),
      Owl.Data.tag(" ──────────────────────", :faint)
    ])
  end

  @doc """
  Print the agent's thought/text for a step.
  """
  def agent_text(text) when is_binary(text) do
    puts([Owl.Data.tag("  ", :white), Owl.Data.tag(text, :white)])
  end
  def agent_text(_), do: :ok

  @doc """
  Print a tool call summary line.
  """
  def tool_call(name, detail) do
    Owl.LiveScreen.update(:statusbar, fn state ->
      %{state | action: "#{name} #{detail}"}
    end)

    puts([
      "  ",
      Owl.Data.tag("▶ #{name}", :magenta),
      " ",
      Owl.Data.tag(truncate_text(detail, 70), :faint)
    ])
  end

  @doc """
  Print a tool result summary.
  """
  def tool_result(text) when is_binary(text) do
    # Show first meaningful line of output, truncated
    summary =
      text
      |> String.split("\n", trim: true)
      |> List.first("")
      |> truncate_text(80)

    if summary != "" do
      puts([
        "    ",
        Owl.Data.tag("→ ", :green),
        Owl.Data.tag(summary, :faint)
      ])
    end
  end
  def tool_result(_), do: :ok

  @doc """
  Print a tool error/failure.
  """
  def tool_error(text) do
    puts([
      "    ",
      Owl.Data.tag("✗ ", :red),
      Owl.Data.tag(truncate_text(text, 80), [:faint, :red])
    ])
  end

  @doc """
  Print a planning/replanning message.
  """
  def planning(label \\ "Planning with Opus...") do
    puts([Owl.Data.tag("⠋ #{label}", :yellow)])
  end

  @doc """
  Print plan created confirmation.
  """
  def plan_created(plan) do
    # Count phases and steps
    phases = Regex.scan(~r/^## /m, plan) |> length()
    steps = Regex.scan(~r/- \[ \]/m, plan) |> length()

    puts([
      Owl.Data.tag("✓ Plan created", :green),
      Owl.Data.tag(" (#{phases} phases, #{steps} steps)", :faint)
    ])
    puts("")
  end

  @doc """
  Print run completion.
  """
  def run_complete(success, summary) do
    Owl.LiveScreen.update(:statusbar, fn state -> %{state | action: nil} end)

    puts("")
    if success do
      puts([Owl.Data.tag("✓ ", :green), Owl.Data.tag("Goal achieved", :green)])
    else
      puts([Owl.Data.tag("✗ ", :red), Owl.Data.tag("Goal not achieved", :red)])
    end
    puts([Owl.Data.tag("  #{truncate_text(summary, 120)}", :faint)])
  end

  @doc """
  Print a run paused message.
  """
  def run_paused(run_id) do
    puts("")
    puts([
      Owl.Data.tag("⏸ Paused", :yellow),
      Owl.Data.tag(" — resume with: ", :faint),
      Owl.Data.tag("mix penbot.resume #{run_id}", :white)
    ])
  end

  @doc """
  Print a run error.
  """
  def run_error(reason) do
    puts("")
    puts([Owl.Data.tag("✗ Error: #{inspect(reason)}", :red)])
  end

  @doc """
  Set the full progress list. Each item is %{text, status}.
  """
  def set_progress(items) do
    Owl.LiveScreen.update(:statusbar, fn state -> %{state | progress: items} end)
  end

  @doc """
  Clean up and flush the display.
  """
  def stop do
    try do
      Owl.LiveScreen.flush()
    catch
      :exit, _ -> :ok
    end

    Logger.configure(level: :info)
  end

  # --- Status Bar Renderer (pinned at bottom) ---

  defp render_statusbar(%{step: step, max_steps: max, cost: cost, progress: progress, action: action}) do
    # Progress bar
    bar_width = 20
    pct = if max > 0, do: min(step / max, 1.0), else: 0
    filled = round(pct * bar_width)
    empty = bar_width - filled

    bar_line = [
      Owl.Data.tag(String.duplicate("█", filled), :green),
      Owl.Data.tag(String.duplicate("░", empty), :faint),
      " ",
      Owl.Data.tag("#{step}/#{max}", :white),
      Owl.Data.tag(" │ ", :faint),
      Owl.Data.tag(cost, :yellow)
    ]

    # Progress items (compact, single line each)
    progress_lines =
      case progress do
        [] -> []
        items ->
          Enum.map(items, fn item ->
            {icon, color} =
              case item.status do
                :completed -> {"✓", :green}
                :in_progress -> {"→", :yellow}
                :pending -> {"·", :faint}
              end

            text_style = if item.status == :pending, do: :faint, else: :white

            [
              Owl.Data.tag(" [", :faint),
              Owl.Data.tag(icon, color),
              Owl.Data.tag("] ", :faint),
              Owl.Data.tag(truncate_text(item.text, 50), text_style)
            ]
          end)
      end

    # Current action
    action_line =
      if action do
        [Owl.Data.tag(" ⠋ #{truncate_text(action, 60)}", [:faint, :magenta])]
      else
        []
      end

    [bar_line | progress_lines ++ [action_line]]
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse("\n")
    |> List.flatten()
  end

  # --- Helpers ---

  defp puts(data) do
    Owl.IO.puts(data)
  end

  defp truncate_text(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max - 3) <> "..."
    else
      text
    end
  end
  defp truncate_text(_, _), do: ""
end
