defmodule Golem.TUI do
  @moduledoc """
  Terminal UI with scrolling output and a fixed status area.

  Before printing any new line, the status area is erased.
  After printing, the status area is redrawn at the bottom.
  This keeps the status pinned at the bottom.
  """

  @behaviour Golem.Output

  use GenServer
  require Logger

  @spinner_frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  @spinner_interval 500

  @forge_verbs [
    "Forging", "Hammering", "Smelting", "Tempering", "Quenching",
    "Annealing", "Casting", "Welding", "Shaping", "Refining"
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Public API (Golem.Output callbacks) ---

  @impl true
  def init_display(run_id, goal) do
    GenServer.call(__MODULE__, {:init, run_id, goal})
  end

  @impl true
  def step_header(step, max_steps, cost_str) do
    GenServer.cast(__MODULE__, {:update, cost: cost_str, step: step, max_steps: max_steps})
  end

  @impl true
  def agent_text(nil), do: :ok
  @impl true
  def agent_text(text) do
    width = terminal_width() - 4  # leave room for "● " prefix + margin
    lines = wrap_text(text, width)
    formatted = case lines do
      [] -> [[], [:cyan, "● ", :reset]]
      [first | rest] ->
        [[] | [[:cyan, "● ", :reset, first] | Enum.map(rest, &[:faint, "  ", :reset, &1])]]
    end
    GenServer.call(__MODULE__, {:print, formatted, :agent_text})
  end

  @impl true
  def tool_call(name, detail) do
    GenServer.cast(__MODULE__, {:update, action: "#{name} #{detail}"})
  end

  @impl true
  def tool_result(name, detail, result, elapsed_ms, _tokens) do
    elapsed = format_elapsed(elapsed_ms)
    summary = result_oneliner(result)
    time_part = if name == "think", do: [], else: [:faint, " (#{elapsed})", :reset]
    lines = [
      [:faint, "  #{tool_icon(name)} ", :reset, :white, tool_label(name, detail), :reset] ++ time_part
    ]
    lines = if summary != "", do: lines ++ [[:faint, "  └ #{summary}", :reset]], else: lines
    GenServer.call(__MODULE__, {:print_and_update, lines, [action: nil]})
  end

  @impl true
  def tool_error(name, detail, error_text) do
    # Show first meaningful line of error, wrapped
    first_line = error_text |> String.split("\n", trim: true) |> List.first("") |> wtrunc(6)
    lines = [
      [:red, "  ✗ ", :reset, :red, tool_label(name, detail), :reset],
      [:faint, :red, "  └ #{first_line}", :reset]
    ]
    GenServer.call(__MODULE__, {:print_and_update, lines, [action: nil]})
  end

  @impl true
  def show_diff(path, old_content, new_content) do
    diff_lines = build_diff(path, old_content, new_content)
    if diff_lines != [] do
      added = added_lines(diff_lines)
      removed = removed_lines(diff_lines)
      summary = [[:faint, "    #{Path.basename(path)}: ",
        :green, "+#{added}", :faint, " / ",
        :red, "-#{removed}", :faint, " lines", :reset]]
      GenServer.call(__MODULE__, {:print_raw, summary ++ Enum.map(diff_lines, &[&1]) ++ [[]]})
    end
  end

  @impl true
  def show_phase_costs(phase_costs) do
    lines = [[], [:faint, "  Cost breakdown:", :reset]] ++
      Enum.map(phase_costs, fn {name, cost} ->
        [:white, "    #{name}: ", :yellow, "$#{cost}", :reset]
      end)
    GenServer.call(__MODULE__, {:print, lines})
  end

  @impl true
  def set_progress(items) do
    GenServer.call(__MODULE__, {:set_progress, items})
  end

  @impl true
  def planning(label \\ "Planning...") do
    GenServer.call(__MODULE__, {:print, [[:yellow, "+ #{label}", :reset]], :planning})
  end

  @impl true
  def plan_created(plan) do
    phases = Regex.scan(~r/^## /m, plan) |> length()
    steps = Regex.scan(~r/- \[ \]/m, plan) |> length()
    GenServer.call(__MODULE__, {:print, [
      [],
      [:green, "✓ Plan created ", :reset, :faint, "(#{phases} phases, #{steps} steps)", :reset]
    ], :plan_created})
  end

  def replan_start, do: planning("Re-planning with Opus...")

  def replan_done do
    GenServer.call(__MODULE__, {:print, [[:green, "✓ Plan revised", :reset]]})
  end

  @impl true
  def tool_batch_start(items) do
    GenServer.call(__MODULE__, {:batch_start, items})
  end

  @impl true
  def tool_batch_item_done(id, outcome) do
    GenServer.call(__MODULE__, {:batch_item_done, id, outcome})
  end

  @impl true
  def api_retry(attempt, max, delay_ms, reason) do
    GenServer.cast(__MODULE__, {:api_retry, attempt, max, delay_ms, reason})
  end

  @impl true
  def api_retry_cleared do
    GenServer.cast(__MODULE__, :api_retry_cleared)
  end

  @impl true
  def confirm_continue(question, opts \\ []) do
    GenServer.call(__MODULE__, {:confirm_continue, question, opts}, :infinity)
  end

  @impl true
  def sub_agent_block(label, entries, success, steps) do
    GenServer.call(__MODULE__, {:sub_agent_block, label, entries, success, steps})
  end

  @impl true
  def pr_opened(repo, url) do
    # Plain underlined cyan URL — modern terminals auto-detect it as
    # clickable. An earlier version used an OSC 8 hyperlink escape for
    # "proper" click support but the sequence confused the ANSI-aware
    # truncator (it doesn't recognize OSC 8, so it counted the URL
    # bytes toward visible width and clipped the rest of the line),
    # and the `<>` concatenation crashed on iodata.
    GenServer.call(__MODULE__, {:print, [
      [:green, "  ✓ ", :reset, :bright, repo, :reset,
       :faint, "  →  ", :reset, :cyan, :underline, url, :reset]
    ], :pr_opened})
  end

  @impl true
  def pr_skipped(repo, reason) do
    GenServer.call(__MODULE__, {:print, [
      [:faint, "  · #{repo}  —  #{reason}", :reset]
    ], :pr_skipped})
  end

  def sub_agent_start(goal, display_name \\ nil) do
    label = display_name || trunc(goal, 60)
    GenServer.call(__MODULE__, {:sub_agent_start, label})
  end

  def sub_agent_result(_goal, steps, success) do
    {icon, color} = if success, do: {"✓", :green}, else: {"✗", :red}
    GenServer.call(__MODULE__, {:sub_agent_end, icon, color, steps})
  end

  @impl true
  def sub_agent_status(goal, tool, detail, step, max_steps) do
    # When display_name was passed to sub_agent_start, prefer the
    # shorter form. For the adversarial verifier the goal is ~1500
    # chars of instructions; showing it in the status line corrupts
    # the TUI. Fall back to a short goal truncation.
    short_goal = trunc(goal, 40)
    label = tool_label(tool, detail) |> trunc(55)
    GenServer.call(__MODULE__, {:print_and_update, [
      [:faint, "  │ ", :magenta, tool_icon(tool), :reset, :faint, " #{label}", :reset]
    ], [action: "↳ #{short_goal} (#{step}/#{max_steps})"]})
  end

  @impl true
  def tool_batch_result(_results, _elapsed), do: :ok

  @impl true
  def update_cost(cost_str) do
    GenServer.cast(__MODULE__, {:update, cost: cost_str})
  end

  @impl true
  def update_tokens(_count), do: :ok

  @impl true
  def run_complete(success, summary) do
    lines = [[]] ++
      if success do
        [[:green, :bright, "✓ Goal achieved", :reset]]
      else
        [[:red, :bright, "✗ Goal not achieved", :reset]]
      end ++ [[:faint, "  #{wtrunc(summary, 4)}", :reset]]
    GenServer.call(__MODULE__, {:print_and_update, lines, [action: nil]})
  end

  @impl true
  def run_paused(run_id) do
    GenServer.call(__MODULE__, {:print, [
      [],
      [:yellow, "⏸ Paused", :reset, :faint, " — resume: ", :reset, "mix golem.resume #{run_id}"]
    ]})
  end

  @impl true
  def run_error(reason) do
    GenServer.call(__MODULE__, {:print, [[:red, "✗ Error: #{inspect(reason)}", :reset]]})
  end

  @impl true
  def stop_display do
    GenServer.call(__MODULE__, :stop)
  end

  # Streaming stubs (not used — non-streaming mode)
  def stream_start, do: :ok
  def stream_text(_chunk), do: :ok
  def stream_end, do: :ok

  # Public helpers
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
      active: false, cost: "$0.0000", step: 0, max_steps: 0,
      progress: [], action: nil, status_lines: 0,
      pending_batch: [],
      retry: nil,
      started_at: nil, spinner_idx: 0, verb: Enum.random(@forge_verbs),
      ticker: nil, last_output: nil, sub_agent_depth: 0
    }}
  end

  @impl true
  def handle_call({:init, _run_id, _goal}, _from, %{active: true} = state) do
    # Idempotent: the Jira integration calls init_display early so the
    # status bar is visible during fetch/eval/setup, and Runner.run
    # calls it again when the agent loop starts. Re-printing the
    # header and restarting the ticker would corrupt the TUI.
    {:reply, :ok, state}
  end

  def handle_call({:init, run_id, goal}, _from, state) do
    # Suppress ALL console logger handlers — not just :default.
    # Nostrum/Gun deps may add extra handlers. Any console output
    # outside the GenServer corrupts cursor tracking.
    for id <- :logger.get_handler_ids(), id != :golem_file do
      :logger.set_handler_config(id, :level, :none)
    end
    IO.write("\e[?25l")  # Hide cursor
    width = terminal_width() - 4
    goal_lines =
      goal
      |> String.split("\n", trim: true)
      |> Enum.take(5)
      |> Enum.flat_map(&wrap_text(&1, width))
      |> Enum.map(fn line -> IO.ANSI.format([:faint, "  #{line}", :reset]) end)

    IO.puts("")
    IO.puts(IO.ANSI.format([:cyan, "● ", :reset, :bright, "Forge ", :reset, :faint, run_id, :reset]))
    Enum.each(goal_lines, &IO.puts/1)
    IO.puts("")

    {:ok, ticker} = :timer.send_interval(@spinner_interval, :tick)

    {:reply, :ok, %{state |
      active: true, status_lines: 0,
      started_at: System.monotonic_time(:second),
      verb: Enum.random(@forge_verbs),
      ticker: ticker
    }}
  end

  def handle_call({:print, lines}, _from, state) do
    state = erase_status(state)
    Enum.each(lines, &print_line/1)
    state = draw_status(%{state | last_output: :other})
    {:reply, :ok, state}
  end

  def handle_call({:print, lines, output_type}, _from, state) do
    state = erase_status(state)

    # Add spacing based on what came before
    lines =
      case {output_type, state.last_output} do
        # Planning after planning — no blank line (group them)
        {:planning, :planning} -> lines
        # Planning after anything else — blank line before
        {:planning, _} -> [[] | lines]
        # Agent text already includes its own leading blank line
        _ -> lines
      end

    Enum.each(lines, &print_line/1)
    state = draw_status(%{state | last_output: output_type})
    {:reply, :ok, state}
  end

  def handle_call({:print_raw, lines}, _from, state) do
    state = erase_status(state)
    max_w = terminal_width() - 1
    Enum.each(lines, fn
      [] -> IO.puts("")
      [raw] when is_binary(raw) -> IO.puts(truncate_visible(raw, max_w))
      tokens -> print_line(tokens)
    end)
    state = draw_status(state)
    {:reply, :ok, state}
  end

  def handle_call({:print_and_update, lines, updates}, _from, state) do
    state = erase_status(state)
    Enum.each(lines, &print_line/1)
    state = Enum.reduce(updates, state, fn {k, v}, s -> Map.put(s, k, v) end)
    state = draw_status(%{state | last_output: :other})
    {:reply, :ok, state}
  end

  def handle_call({:set_progress, items}, _from, state) do
    state = erase_status(state)
    state = %{state | progress: items}
    state = draw_status(state)
    {:reply, :ok, state}
  end

  def handle_call({:batch_start, items}, _from, state) do
    state = erase_status(state)

    pending =
      Enum.map(items, fn %{id: id, name: name, detail: detail} ->
        %{id: id, name: name, detail: detail, status: :pending, elapsed_ms: nil}
      end)

    # Blank line before the batch so it visually separates from prior output.
    if state.pending_batch == [] and pending != [], do: print_line([])

    state = %{state | pending_batch: pending, action: nil}
    state = draw_status(state)
    {:reply, :ok, state}
  end

  def handle_call({:batch_item_done, id, outcome}, _from, state) do
    state = erase_status(state)

    {status, elapsed_ms} =
      case outcome do
        {:ok, ms} -> {:ok, ms}
        {:error, ms} -> {:error, ms}
      end

    pending =
      Enum.map(state.pending_batch, fn item ->
        if item.id == id, do: %{item | status: status, elapsed_ms: elapsed_ms}, else: item
      end)

    all_terminal = pending != [] and Enum.all?(pending, &(&1.status != :pending))

    state =
      if all_terminal do
        # Promote the completed batch to the scroll buffer so it persists.
        Enum.each(pending, fn item -> print_line(batch_item_line(item)) end)
        %{state | pending_batch: [], last_output: :other}
      else
        %{state | pending_batch: pending}
      end

    state = draw_status(state)
    {:reply, :ok, state}
  end

  def handle_call({:sub_agent_start, label}, _from, state) do
    state = erase_status(state)
    print_line([])
    print_line([:magenta, "  ● Sub-agent: ", :reset, :faint, label, :reset])

    # Suppress the main-agent progress checklist while a sub-agent
    # runs. It doesn't change during verification/sub-tasks and its
    # continuous redraw was the leading cause of the "stacked
    # checklist" visual bug during long sub-agent runs.
    state = %{state | sub_agent_depth: state.sub_agent_depth + 1, last_output: :sub_agent, action: nil}
    state = draw_status(state)
    {:reply, :ok, state}
  end

  def handle_call({:sub_agent_end, icon, color, steps}, _from, state) do
    state = erase_status(state)
    print_line([])
    print_line([color, "  #{icon} Sub-agent done ", :reset, :faint, "· #{steps} steps", :reset])
    state = %{state |
      sub_agent_depth: max(state.sub_agent_depth - 1, 0),
      last_output: :sub_agent,
      action: nil
    }
    state = draw_status(state)
    {:reply, :ok, state}
  end

  def handle_call({:sub_agent_block, label, entries, success, steps}, _from, state) do
    state = erase_status(state)
    print_line([])
    print_line([:magenta, "  ● Sub-agent: ", :reset, :faint, label, :reset])

    Enum.each(entries, fn {tool, detail, _step} ->
      tool_label_text = tool_label(tool, detail) |> trunc(55)
      print_line([
        :faint, "  │ ", :magenta, tool_icon(tool), :reset, :faint, " ", tool_label_text, :reset
      ])
    end)

    {icon, color} = if success, do: {"✓", :green}, else: {"✗", :red}
    print_line([color, "  #{icon} Sub-agent done ", :reset, :faint, "· #{steps} steps", :reset])

    state = draw_status(%{state | last_output: :sub_agent, action: nil})
    {:reply, :ok, state}
  end

  def handle_call(:stop, _from, state) do
    if state.ticker, do: :timer.cancel(state.ticker)
    state = erase_status(state)
    elapsed = format_duration(System.monotonic_time(:second) - (state.started_at || 0))
    IO.puts(IO.ANSI.format([:faint, " #{state.verb} took #{elapsed} · #{state.cost}", :reset]))
    IO.write("\e[?25h")  # Restore cursor
    for id <- :logger.get_handler_ids(), id != :golem_file do
      :logger.set_handler_config(id, :level, :debug)
    end
    {:reply, :ok, %{state | active: false, status_lines: 0, ticker: nil}}
  end

  def handle_call({:confirm_continue, question, _opts}, _from, state) do
    # Pause the spinner: cancel ticker, erase status block. We re-arm
    # both after reading input so the run resumes cleanly whether the
    # user said yes or no. No timeout — the run hangs here until the
    # operator responds, on the assumption that they may be AFK and
    # don't want a wrong answer billed to them.
    if state.ticker, do: :timer.cancel(state.ticker)
    state = erase_status(state)

    IO.write("\e[?25h")  # show cursor
    IO.puts("")
    IO.puts(IO.ANSI.format([:yellow, "● ", :reset, :bright, question, :reset]))
    IO.write(
      IO.ANSI.format([:faint, "  [y]es to continue, anything else aborts: ", :reset])
    )

    answer =
      case IO.gets("") do
        :eof -> :eof
        line when is_binary(line) -> line |> String.trim() |> String.downcase()
        _ -> :error
      end

    IO.write("\e[?25l")  # hide cursor
    {:ok, ticker} = :timer.send_interval(@spinner_interval, :tick)
    state = draw_status(%{state | ticker: ticker})

    reply =
      case answer do
        "y" -> :continue
        "yes" -> :continue
        _ -> :abort
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:tick, %{active: true, status_lines: n} = state) when n > 0 do
    state = erase_status(state)
    state = %{state | spinner_idx: rem(state.spinner_idx + 1, length(@spinner_frames))}
    state = draw_status(state)
    {:noreply, state}
  end

  def handle_info(:tick, %{active: true} = state) do
    {:noreply, %{state | spinner_idx: rem(state.spinner_idx + 1, length(@spinner_frames))}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:update, updates}, state) do
    state = erase_status(state)
    state = Enum.reduce(updates, state, fn {k, v}, s -> Map.put(s, k, v) end)
    state = draw_status(state)
    {:noreply, state}
  end

  def handle_cast({:api_retry, attempt, max, delay_ms, reason}, state) do
    state = erase_status(state)

    retry = %{
      attempt: attempt,
      max: max,
      delay_ms: delay_ms,
      reason: reason,
      started_at: System.monotonic_time(:millisecond)
    }

    state = draw_status(%{state | retry: retry})
    {:noreply, state}
  end

  def handle_cast(:api_retry_cleared, state) do
    state = erase_status(state)
    state = draw_status(%{state | retry: nil})
    {:noreply, state}
  end

  # --- Status Area ---
  #
  # The status area is a block of lines pinned at the bottom of the terminal.
  # It contains the progress checklist and the spinner line.
  # Before printing any output, erase_status moves the cursor up and clears
  # the lines. After printing, draw_status redraws them. This ensures the
  # status area is always at the bottom and never interleaves with output.

  defp erase_status(%{status_lines: 0} = state), do: state
  defp erase_status(%{status_lines: n} = state) do
    IO.write("\e[#{n}A\e[J")
    %{state | status_lines: 0}
  end

  defp draw_status(%{active: false} = state), do: state
  defp draw_status(state) do
    lines = build_status_lines(state)
    max_w = terminal_width() - 1
    buf =
      lines
      |> Enum.map(fn line ->
        formatted = IO.ANSI.format(line) |> IO.chardata_to_string()
        ["\e[2K", truncate_visible(formatted, max_w)]
      end)
      |> Enum.intersperse("\n")
    IO.write([buf, "\n"])
    %{state | status_lines: length(lines)}
  end

  defp build_bottom_line(state) do
    spinner = Enum.at(@spinner_frames, state.spinner_idx)
    elapsed = if state.started_at, do: format_duration(System.monotonic_time(:second) - state.started_at), else: "0s"
    action_part = if state.action, do: [:faint, " · ", :magenta, wtrunc(state.action, 30), :reset], else: []

    [:cyan, " #{spinner} ", :reset,
     :white, "#{state.verb} for #{elapsed}", :reset,
     :faint, " · ", :yellow, state.cost, :reset] ++ action_part
  end

  defp build_status_lines(state) do
    # While a sub-agent is active, skip the progress checklist — the
    # main agent's items don't change during sub-agent execution, and
    # the repeated redraws visibly leak copies into scrollback on some
    # terminals. A single-line status (blank + spinner) is enough and
    # far more robust.
    progress_lines =
      if state.sub_agent_depth > 0 do
        []
      else
        Enum.map(state.progress, fn item ->
          {icon, color} = case item.status do
            :completed -> {"✓", :green}
            :done -> {"✓", :faint}
            :in_progress -> {"→", :yellow}
            :pending -> {"·", :faint}
          end
          style = if item.status in [:pending, :done], do: :faint, else: :white
          [:faint, " [", color, icon, :reset, :faint, "] ", :reset, style, wtrunc(item.text, 6), :reset]
        end)
      end

    # Only render the pending-batch block when there are at least 2
    # items. A 1-item "batch" is just a single tool call and already
    # flows through the tool_call/tool_result pattern in the scroll
    # buffer — rendering it again in the status area is noise.
    batch_lines =
      if length(state.pending_batch) >= 2 do
        Enum.map(state.pending_batch, &batch_item_line/1)
      else
        []
      end

    bottom = build_bottom_line(state)

    retry_line =
      case state.retry do
        nil -> []
        r -> [retry_status_line(r)]
      end

    # Layout (top → bottom):
    #   blank
    #   todo checklist (plan-level state, stable across turns)
    #   blank
    #   spinner + elapsed + cost      (overall run)
    #   pending batch items           (current live activity)
    #   retry indicator               (transient network issue)
    progress_sep = if progress_lines != [], do: [[]], else: []
    [[]] ++ progress_lines ++ progress_sep ++ [bottom] ++ batch_lines ++ retry_line
  end

  # One-line retry indicator rendered directly under the spinner.
  # Remaining seconds are computed from `started_at` so the existing
  # spinner ticker (80 ms) drives a live countdown for free.
  defp retry_status_line(%{attempt: attempt, max: max, delay_ms: delay_ms, reason: reason, started_at: started_at}) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    remaining_ms = max(delay_ms - elapsed_ms, 0)
    remaining_s = div(remaining_ms, 1000)

    [:faint, "  ↳ Retrying in ", :reset, :yellow, "#{remaining_s}s",
     :reset, :faint, " · attempt #{attempt}/#{max} · #{reason}", :reset]
  end

  # Single line representing one tool in a concurrent batch, either
  # pending (faint ○), done (green ✓ + elapsed), or errored (red ✗).
  @doc false
  def batch_item_line(%{status: :pending, name: name, detail: detail}) do
    [:faint, "  ○ ", :reset, :faint, tool_label(name, detail), :reset]
  end

  def batch_item_line(%{status: :ok, name: name, detail: detail, elapsed_ms: ms}) do
    [:green, "  ✓ ", :reset, :white, tool_label(name, detail), :reset,
     :faint, " (#{format_elapsed(ms)})", :reset]
  end

  def batch_item_line(%{status: :error, name: name, detail: detail, elapsed_ms: ms}) do
    [:red, "  ✗ ", :reset, :red, tool_label(name, detail), :reset,
     :faint, " (#{format_elapsed(ms)})", :reset]
  end

  # --- Helpers ---

  defp print_line([]), do: IO.puts("")
  defp print_line(tokens) do
    formatted = IO.ANSI.format(tokens) |> IO.chardata_to_string()
    IO.puts(truncate_visible(formatted, terminal_width() - 1))
  end

  # Truncate a string containing ANSI escapes to a visible width.
  @doc false
  def truncate_visible(str, max_width) do
    {result, _visible} =
      Regex.split(~r/(\e\[[0-9;]*m)/, str, include_captures: true)
      |> Enum.reduce({"", 0}, fn segment, {acc, visible} ->
        if String.starts_with?(segment, "\e[") do
          {acc <> segment, visible}
        else
          remaining = max_width - visible
          if remaining <= 0 do
            {acc, visible}
          else
            taken = String.slice(segment, 0, remaining)
            {acc <> taken, visible + String.length(taken)}
          end
        end
      end)
    result <> "\e[0m"
  end

  defp terminal_width do
    case :io.columns() do
      {:ok, cols} -> cols
      _ -> 80
    end
  end

  @doc false
  def wrap_text(text, width) when width > 10 do
    text
    |> String.split("\n")
    |> Enum.flat_map(&wrap_line(&1, width))
  end
  def wrap_text(text, _width), do: [text]

  defp wrap_line("", _width), do: [""]
  defp wrap_line(line, width) do
    words = String.split(line, " ")
    do_wrap(words, width, "", [])
  end

  defp do_wrap([], _width, current, acc) do
    Enum.reverse([current | acc])
  end
  defp do_wrap([word | rest], width, "", acc) do
    do_wrap(rest, width, word, acc)
  end
  defp do_wrap([word | rest], width, current, acc) do
    candidate = current <> " " <> word
    if String.length(candidate) > width do
      do_wrap([word | rest], width, "", [current | acc])
    else
      do_wrap(rest, width, candidate, acc)
    end
  end

  @doc false
  def format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  def format_duration(seconds) do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    if secs == 0, do: "#{mins}m", else: "#{mins}m #{secs}s"
  end

  defp trunc(text, max) when is_binary(text) do
    if String.length(text) > max, do: String.slice(text, 0, max - 3) <> "...", else: text
  end
  defp trunc(_, _), do: ""

  # Truncate relative to terminal width, with a prefix offset for indentation
  defp wtrunc(text, offset) when is_binary(text) do
    max = max(terminal_width() - offset, 40)
    trunc(text, max)
  end
  defp wtrunc(_, _), do: ""

  @doc false
  def tool_icon("shell"), do: "$"
  def tool_icon("write_file"), do: "+"
  def tool_icon("read_file"), do: "↓"
  def tool_icon("edit_file"), do: "~"
  def tool_icon("glob"), do: "⌕"
  def tool_icon("grep"), do: "⌕"
  def tool_icon("web_search"), do: "?"
  def tool_icon("web_fetch"), do: "↓"
  def tool_icon("screenshot"), do: "◉"
  def tool_icon("think"), do: "·"
  def tool_icon("update_progress"), do: "·"
  def tool_icon("done"), do: "✓"
  def tool_icon("sub_agent"), do: "●"
  def tool_icon("ask_user"), do: "?"
  def tool_icon("browse"), do: "◎"
  def tool_icon(_), do: "▸"

  @doc false
  def tool_label("shell", cmd), do: wtrunc(cmd, 6)
  def tool_label("write_file", path), do: "Write #{path}"
  def tool_label("read_file", path), do: "Read #{path}"
  def tool_label("edit_file", path), do: "Edit #{path}"
  def tool_label("glob", pattern), do: "Glob #{pattern}"
  def tool_label("grep", pattern), do: "Grep #{pattern}"
  def tool_label("web_search", query), do: "Search · #{wtrunc(query, 14)}"
  def tool_label("web_fetch", url), do: "Fetch #{wtrunc(url, 12)}"
  def tool_label("list_directory", path), do: "List #{path}"
  def tool_label("sub_agent", goal), do: "Sub-agent · #{wtrunc(goal, 18)}"
  def tool_label("update_progress", _), do: "Progress update"
  def tool_label("done", _), do: "Done"
  def tool_label("think", _), do: "Thinking..."
  def tool_label("ask_user", _), do: "Asking user..."
  def tool_label("browse", url), do: "Browse #{wtrunc(url, 12)}"
  def tool_label(name, _), do: name

  defp build_diff(path, old, new) do
    old_lines = String.split(old, "\n")
    new_lines = String.split(new, "\n")

    {prefix_len, _} =
      Enum.zip(old_lines, new_lines)
      |> Enum.with_index()
      |> Enum.find({length(old_lines), nil}, fn {{a, b}, _} -> a != b end)
      |> then(fn {_, idx} -> {idx || 0, nil} end)

    {suffix_len, _} =
      Enum.zip(Enum.reverse(old_lines), Enum.reverse(new_lines))
      |> Enum.with_index()
      |> Enum.find({length(old_lines), nil}, fn {{a, b}, _} -> a != b end)
      |> then(fn {_, idx} -> {idx || 0, nil} end)

    ctx = 2
    start = max(0, prefix_len - ctx)
    old_end = min(length(old_lines), length(old_lines) - suffix_len + ctx)
    new_end = min(length(new_lines), length(new_lines) - suffix_len + ctx)
    lang = lang_from_path(path)

    removed =
      old_lines
      |> Enum.slice(start..min(old_end, length(old_lines) - 1)//1)
      |> Enum.with_index(start + 1)
      |> Enum.map(fn {line, num} ->
        hl = highlight_line(line, lang)
        if num > prefix_len and num <= length(old_lines) - suffix_len do
          "    \e[31m- #{num}: #{hl}\e[0m"
        else
          "    \e[2m  #{num}: #{hl}\e[0m"
        end
      end)

    added =
      new_lines
      |> Enum.slice(start..min(new_end, length(new_lines) - 1)//1)
      |> Enum.with_index(start + 1)
      |> Enum.map(fn {line, num} ->
        hl = highlight_line(line, lang)
        if num > prefix_len and num <= length(new_lines) - suffix_len do
          "    \e[32m+ #{num}: #{hl}\e[0m"
        else
          "    \e[2m  #{num}: #{hl}\e[0m"
        end
      end)

    (removed ++ added) |> Enum.take(20)
  end

  defp added_lines(diff_lines), do: Enum.count(diff_lines, &String.contains?(&1, "\e[32m+"))
  defp removed_lines(diff_lines), do: Enum.count(diff_lines, &String.contains?(&1, "\e[31m-"))

  defp result_oneliner(text) when is_binary(text) do
    text |> String.split("\n", trim: true) |> List.first("") |> trunc(90)
  end
  defp result_oneliner(_), do: ""

  # --- Syntax Highlighting ---

  defp highlight_line("", _lang), do: ""
  defp highlight_line(line, nil), do: line
  defp highlight_line(line, lang) do
    case bat_path() do
      nil -> line
      bat ->
        try do
          case System.cmd(bat, ["--color=always", "--style=plain", "--language=#{lang}",
                 "--paging=never", "-"], input: line, stderr_to_stdout: true) do
            {highlighted, 0} -> String.trim_trailing(highlighted)
            _ -> line
          end
        rescue
          _ -> line
        end
    end
  end

  defp bat_path do
    case :persistent_term.get(:bat_path, :not_checked) do
      :not_checked ->
        path = System.find_executable("bat")
        :persistent_term.put(:bat_path, path)
        path
      path -> path
    end
  end

  defp lang_from_path(path) do
    case Path.extname(path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".php" -> "php"
      ".py" -> "python"
      ".js" -> "javascript"
      ".ts" -> "typescript"
      ".tsx" -> "tsx"
      ".jsx" -> "jsx"
      ".rb" -> "ruby"
      ".rs" -> "rust"
      ".go" -> "go"
      ".sh" -> "bash"
      ".json" -> "json"
      ".yaml" -> "yaml"
      ".yml" -> "yaml"
      ".toml" -> "toml"
      ".html" -> "html"
      ".css" -> "css"
      ".sql" -> "sql"
      ".md" -> "markdown"
      _ -> nil
    end
  end
end
