defmodule Penbot.TUI do
  @moduledoc """
  Terminal UI with scrolling output and a fixed status area at the bottom.

  Uses raw ANSI escape codes to maintain a reserved area at the bottom
  of the terminal for progress checklist and cost. Scrolling output
  (thoughts, tool calls) prints above this area.
  """

  use GenServer
  require Logger

  @status_lines 12

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Public API ---

  def init_display(run_id, goal) do
    GenServer.cast(__MODULE__, {:init, run_id, goal})
  end

  def step_header(step, max_steps, cost_str) do
    GenServer.cast(__MODULE__, {:step, step, max_steps, cost_str})
  end

  def agent_text(nil), do: :ok
  def agent_text(text), do: GenServer.cast(__MODULE__, {:agent_text, text})

  def tool_call(name, detail) do
    GenServer.cast(__MODULE__, {:tool_call, name, detail})
  end

  def tool_result(name, detail, result, elapsed_ms, _tokens) do
    GenServer.cast(__MODULE__, {:tool_result, name, detail, result, elapsed_ms})
  end

  def tool_error(name, detail, error_text) do
    GenServer.cast(__MODULE__, {:tool_error, name, detail, error_text})
  end

  def set_progress(items) do
    GenServer.cast(__MODULE__, {:progress, items})
  end

  def planning(label \\ "Planning...") do
    GenServer.cast(__MODULE__, {:scroll, [tag("+ ", :yellow), tag(label, :yellow)]})
  end

  def plan_created(plan) do
    phases = Regex.scan(~r/^## /m, plan) |> length()
    steps = Regex.scan(~r/- \[ \]/m, plan) |> length()
    GenServer.cast(__MODULE__, {:scroll, [
      tag("✓ ", :green), tag("Plan created ", :green),
      tag("(#{phases} phases, #{steps} steps)", :faint)
    ]})
  end

  def replan_start, do: planning("Re-planning with Opus...")
  def replan_done, do: GenServer.cast(__MODULE__, {:scroll, [tag("✓ ", :green), tag("Plan revised", :green)]})

  def sub_agent_start(goal) do
    GenServer.cast(__MODULE__, {:scroll, [
      tag("  ● ", :magenta), tag("Sub-agent: ", :magenta), tag(trunc(goal, 70), :faint)
    ]})
  end

  def sub_agent_result(_goal, steps, success) do
    {icon, color} = if success, do: {"✓", :green}, else: {"✗", :red}
    GenServer.cast(__MODULE__, {:scroll, [
      tag("  #{icon} ", color), tag("Sub-agent done ", color), tag("· #{steps} steps", :faint)
    ]})
  end

  def run_complete(success, summary) do
    GenServer.cast(__MODULE__, {:complete, success, summary})
  end

  def run_paused(run_id) do
    GenServer.cast(__MODULE__, {:scroll, [
      tag("⏸ ", :yellow), tag("Paused ", :yellow),
      tag("— resume: ", :faint), tag("mix penbot.resume #{run_id}", :white)
    ]})
  end

  def run_error(reason) do
    GenServer.cast(__MODULE__, {:scroll, [tag("✗ Error: #{inspect(reason)}", :red)]})
  end

  def stop_display do
    GenServer.cast(__MODULE__, :stop_display)
  end

  # Public helpers for runner
  def format_elapsed(nil), do: "..."
  def format_elapsed(ms) when ms < 1000, do: "#{ms}ms"
  def format_elapsed(ms), do: "#{Float.round(ms / 1000, 1)}s"

  def format_tokens(nil), do: ""
  def format_tokens(0), do: ""
  def format_tokens(n) when n < 1000, do: "#{n} tokens"
  def format_tokens(n), do: "#{Float.round(n / 1000, 1)}k tokens"

  # --- GenServer ---

  @impl true
  def init(_opts) do
    {:ok, %{
      active: false,
      step: 0,
      max_steps: 0,
      cost: "$0.0000",
      progress: [],
      action: nil
    }}
  end

  @impl true
  def handle_cast({:init, run_id, goal}, state) do
    Logger.configure(level: :warning)
    goal_short = trunc(goal, 90)

    # Reserve space at bottom for status area
    IO.write(String.duplicate("\n", @status_lines))
    move_up(@status_lines)

    scroll_line([tag("● ", :cyan), tag("Forge ", [:bright, :white]), tag(run_id, :faint)])
    scroll_line([tag("  #{goal_short}", :faint)])
    scroll_line("")

    {:noreply, %{state | active: true}}
  end

  def handle_cast({:step, step, max_steps, cost_str}, state) do
    {:noreply, %{state | step: step, max_steps: max_steps, cost: cost_str, action: nil}
    |> render_status()}
  end

  def handle_cast({:agent_text, text}, state) do
    scroll_line([tag("● ", :cyan), tag(trunc(text, 120), :white)])
    {:noreply, state}
  end

  def handle_cast({:tool_call, name, detail}, state) do
    state = %{state | action: "#{name} #{detail}"}
    {:noreply, render_status(state)}
  end

  def handle_cast({:tool_result, name, detail, result, elapsed_ms}, state) do
    elapsed = format_elapsed(elapsed_ms)
    summary = result_oneliner(result)

    scroll_line([
      tag("  #{tool_icon(name)} ", :faint),
      tag(tool_label(name, detail), :white),
      tag(" (#{elapsed})", :faint)
    ])

    if summary != "" do
      scroll_line([tag("  └ #{summary}", :faint)])
    end

    state = %{state | action: nil}
    {:noreply, render_status(state)}
  end

  def handle_cast({:tool_error, name, detail, error_text}, state) do
    scroll_line([tag("  ✗ ", :red), tag(tool_label(name, detail), :red)])
    scroll_line([tag("  └ #{trunc(error_text, 100)}", [:faint, :red])])
    state = %{state | action: nil}
    {:noreply, render_status(state)}
  end

  def handle_cast({:progress, items}, state) do
    {:noreply, %{state | progress: items} |> render_status()}
  end

  def handle_cast({:scroll, content}, state) do
    scroll_line(content)
    {:noreply, state}
  end

  def handle_cast({:complete, success, summary}, state) do
    scroll_line("")
    if success do
      scroll_line([tag("✓ ", :green), tag("Goal achieved", [:bright, :green])])
    else
      scroll_line([tag("✗ ", :red), tag("Goal not achieved", [:bright, :red])])
    end
    scroll_line([tag("  #{trunc(summary, 120)}", :faint)])
    {:noreply, %{state | action: nil} |> render_status()}
  end

  def handle_cast(:stop_display, state) do
    # Clear the status area and restore normal terminal
    clear_status_area()
    Logger.configure(level: :info)
    {:noreply, %{state | active: false}}
  end

  # --- Rendering ---

  defp render_status(state) do
    if state.active, do: draw_status_area(state)
    state
  end

  defp draw_status_area(state) do
    # Save cursor, move to status area, draw, restore cursor
    IO.write(save_cursor())
    IO.write(move_to_status_area())

    # Clear the status area
    for _ <- 1..@status_lines do
      IO.write("\e[2K\n")
    end
    IO.write(move_to_status_area())

    # Draw progress items
    lines_used = 0

    lines_used =
      Enum.reduce(state.progress, lines_used, fn item, acc ->
        if acc < @status_lines - 2 do
          {icon, color} = case item.status do
            :completed -> {"✓", :green}
            :in_progress -> {"→", :yellow}
            :pending -> {"·", :faint}
          end
          style = if item.status == :pending, do: :faint, else: :white
          IO.write(IO.ANSI.format([
            :faint, " [", color, icon, :faint, "] ",
            style, trunc(item.text, 55), :reset, "\n"
          ]))
          acc + 1
        else
          acc
        end
      end)

    # Draw separator + cost + action on last line
    if lines_used < @status_lines do
      action_text = if state.action, do: " │ ⠋ #{trunc(state.action, 50)}", else: ""
      IO.write(IO.ANSI.format([
        :faint, " ", :yellow, state.cost, :magenta, action_text, :reset
      ]))
    end

    IO.write(restore_cursor())
  end

  defp clear_status_area do
    IO.write(save_cursor())
    IO.write(move_to_status_area())
    for _ <- 1..@status_lines do
      IO.write("\e[2K\n")
    end
    IO.write(restore_cursor())
  end

  # Print a line in the scrolling area (above the status area)
  defp scroll_line(content) do
    # Move up into scroll area, print, scroll down
    IO.write(save_cursor())
    IO.write(move_to_status_area())
    IO.write("\e[L")  # Insert line, pushing status down
    IO.write(restore_cursor())
    IO.write("\e[A")  # Move up one line

    text = if is_list(content), do: IO.ANSI.format(flatten_tags(content)), else: content
    IO.write("#{text}\n")
  end

  # --- ANSI Helpers ---

  defp save_cursor, do: "\e[s"
  defp restore_cursor, do: "\e[u"
  defp move_up(n), do: IO.write("\e[#{n}A")
  defp move_to_status_area, do: "\e[#{@status_lines}B\e[#{@status_lines}A"

  # --- Formatting Helpers ---

  defp tag(text, style) when is_atom(style), do: [style, text, :reset]
  defp tag(text, styles) when is_list(styles), do: styles ++ [text, :reset]

  defp flatten_tags(list) do
    Enum.flat_map(list, fn
      item when is_list(item) -> item
      item -> [item]
    end)
  end

  defp trunc(text, max) when is_binary(text) do
    if String.length(text) > max, do: String.slice(text, 0, max - 3) <> "...", else: text
  end
  defp trunc(_, _), do: ""

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

  defp tool_label("shell", cmd), do: "#{trunc(cmd, 60)}"
  defp tool_label("write_file", path), do: "Write #{path}"
  defp tool_label("read_file", path), do: "Read #{path}"
  defp tool_label("edit_file", path), do: "Edit #{path}"
  defp tool_label("glob", pattern), do: "Glob #{pattern}"
  defp tool_label("grep", pattern), do: "Grep #{pattern}"
  defp tool_label("web_search", query), do: "Search · #{trunc(query, 60)}"
  defp tool_label("web_fetch", url), do: "Fetch #{trunc(url, 60)}"
  defp tool_label("list_directory", path), do: "List #{path}"
  defp tool_label("sub_agent", goal), do: "Sub-agent · #{trunc(goal, 50)}"
  defp tool_label("update_progress", _), do: "Progress update"
  defp tool_label("done", _), do: "Done"
  defp tool_label("think", _), do: "Thinking..."
  defp tool_label("ask_user", _), do: "Asking user..."
  defp tool_label(name, _), do: name

  defp result_oneliner(text) when is_binary(text) do
    text |> String.split("\n", trim: true) |> List.first("") |> trunc(90)
  end
  defp result_oneliner(_), do: ""
end
