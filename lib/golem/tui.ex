defmodule Golem.TUI do
  @moduledoc """
  Terminal UI with scrolling output and a fixed status area.

  Before printing any new line, the status area is erased.
  After printing, the status area is redrawn at the bottom.
  This keeps the status pinned at the bottom.
  """

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

  # --- Public API ---

  def init_display(run_id, goal) do
    GenServer.call(__MODULE__, {:init, run_id, goal})
  end

  def step_header(step, max_steps, cost_str) do
    GenServer.cast(__MODULE__, {:update, cost: cost_str, step: step, max_steps: max_steps})
  end

  def agent_text(nil), do: :ok
  def agent_text(text) do
    GenServer.call(__MODULE__, {:print, [[], [:cyan, "● ", :reset, text]]})
  end

  def tool_call(name, detail) do
    GenServer.cast(__MODULE__, {:update, action: "#{name} #{detail}"})
  end

  def tool_result(name, detail, result, elapsed_ms, _tokens) do
    elapsed = format_elapsed(elapsed_ms)
    summary = result_oneliner(result)
    lines = [
      [:faint, "  #{tool_icon(name)} ", :reset, :white, tool_label(name, detail), :reset, :faint, " (#{elapsed})", :reset]
    ]
    lines = if summary != "", do: lines ++ [[:faint, "  └ #{summary}", :reset]], else: lines
    GenServer.call(__MODULE__, {:print_and_update, lines, [action: nil]})
  end

  def tool_error(name, detail, error_text) do
    lines = [
      [:red, "  ✗ ", :reset, :red, tool_label(name, detail), :reset],
      [:faint, :red, "  └ #{trunc(error_text, 100)}", :reset]
    ]
    GenServer.call(__MODULE__, {:print_and_update, lines, [action: nil]})
  end

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

  def show_phase_costs(phase_costs) do
    lines = [[], [:faint, "  Cost breakdown:", :reset]] ++
      Enum.map(phase_costs, fn {name, cost} ->
        [:white, "    #{name}: ", :yellow, "$#{cost}", :reset]
      end)
    GenServer.call(__MODULE__, {:print, lines})
  end

  def set_progress(items) do
    GenServer.call(__MODULE__, {:set_progress, items})
  end

  def planning(label \\ "Planning...") do
    GenServer.call(__MODULE__, {:print, [[:yellow, "+ #{label}", :reset]]})
  end

  def plan_created(plan) do
    phases = Regex.scan(~r/^## /m, plan) |> length()
    steps = Regex.scan(~r/- \[ \]/m, plan) |> length()
    GenServer.call(__MODULE__, {:print, [
      [:green, "✓ Plan created ", :reset, :faint, "(#{phases} phases, #{steps} steps)", :reset],
      []
    ]})
  end

  def replan_start, do: planning("Re-planning with Opus...")

  def replan_done do
    GenServer.call(__MODULE__, {:print, [[:green, "✓ Plan revised", :reset]]})
  end

  def sub_agent_start(goal) do
    GenServer.call(__MODULE__, {:print, [
      [:magenta, "  ● Sub-agent: ", :reset, :faint, trunc(goal, 70), :reset]
    ]})
  end

  def sub_agent_result(_goal, steps, success) do
    {icon, color} = if success, do: {"✓", :green}, else: {"✗", :red}
    GenServer.call(__MODULE__, {:print, [
      [color, "  #{icon} Sub-agent done ", :reset, :faint, "· #{steps} steps", :reset]
    ]})
  end

  def run_complete(success, summary) do
    lines = [[]] ++
      if success do
        [[:green, :bright, "✓ Goal achieved", :reset]]
      else
        [[:red, :bright, "✗ Goal not achieved", :reset]]
      end ++ [[:faint, "  #{trunc(summary, 120)}", :reset]]
    GenServer.call(__MODULE__, {:print_and_update, lines, [action: nil]})
  end

  def run_paused(run_id) do
    GenServer.call(__MODULE__, {:print, [
      [],
      [:yellow, "⏸ Paused", :reset, :faint, " — resume: ", :reset, "mix golem.resume #{run_id}"]
    ]})
  end

  def run_error(reason) do
    GenServer.call(__MODULE__, {:print, [[:red, "✗ Error: #{inspect(reason)}", :reset]]})
  end

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
      started_at: nil, spinner_idx: 0, verb: Enum.random(@forge_verbs),
      ticker: nil
    }}
  end

  @impl true
  def handle_call({:init, run_id, goal}, _from, state) do
    Logger.configure(level: :warning)
    IO.puts(IO.ANSI.format([:cyan, "● ", :reset, :bright, "Forge ", :reset, :faint, run_id, :reset]))
    IO.puts(IO.ANSI.format([:faint, "  #{goal}", :reset]))
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
    state = draw_status(state)
    {:reply, :ok, state}
  end

  def handle_call({:print_raw, lines}, _from, state) do
    state = erase_status(state)
    Enum.each(lines, fn
      [] -> IO.puts("")
      [raw] when is_binary(raw) -> IO.puts(raw)
      tokens -> print_line(tokens)
    end)
    state = draw_status(state)
    {:reply, :ok, state}
  end

  def handle_call({:print_and_update, lines, updates}, _from, state) do
    state = erase_status(state)
    Enum.each(lines, &print_line/1)
    state = Enum.reduce(updates, state, fn {k, v}, s -> Map.put(s, k, v) end)
    state = draw_status(state)
    {:reply, :ok, state}
  end

  def handle_call({:set_progress, items}, _from, state) do
    state = erase_status(state)
    state = %{state | progress: items}
    state = draw_status(state)
    {:reply, :ok, state}
  end

  def handle_call(:stop, _from, state) do
    if state.ticker, do: :timer.cancel(state.ticker)
    state = erase_status(state)
    elapsed = format_duration(System.monotonic_time(:second) - (state.started_at || 0))
    IO.puts(IO.ANSI.format([:faint, " #{state.verb} took #{elapsed} · #{state.cost}", :reset]))
    Logger.configure(level: :info)
    {:reply, :ok, %{state | active: false, status_lines: 0, ticker: nil}}
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

  # --- Status Area ---

  defp erase_status(%{status_lines: 0} = state), do: state
  defp erase_status(%{status_lines: n} = state) do
    # Move up, clear each line with cursor-down (not \n to avoid scroll buffer leak)
    IO.write("\e[#{n}A")
    for i <- 1..n do
      IO.write("\e[2K")
      if i < n, do: IO.write("\e[1B")
    end
    IO.write("\e[#{n - 1}A\r")
    %{state | status_lines: 0}
  end

  defp draw_status(%{active: false} = state), do: state
  defp draw_status(state) do
    lines = build_status_lines(state)
    Enum.each(lines, fn line ->
      IO.write("\e[2K")
      IO.puts(IO.ANSI.format(line))
    end)
    %{state | status_lines: length(lines)}
  end

  defp build_status_lines(state) do
    progress_lines =
      Enum.map(state.progress, fn item ->
        {icon, color} = case item.status do
          :completed -> {"✓", :green}
          :in_progress -> {"→", :yellow}
          :pending -> {"·", :faint}
        end
        style = if item.status == :pending, do: :faint, else: :white
        [:faint, " [", color, icon, :faint, "] ", :reset, style, trunc(item.text, 55), :reset]
      end)

    spinner = Enum.at(@spinner_frames, state.spinner_idx)
    elapsed = if state.started_at, do: format_duration(System.monotonic_time(:second) - state.started_at), else: "0s"
    action_part = if state.action, do: [:faint, " · ", :magenta, trunc(state.action, 40), :reset], else: []

    bottom = [
      :cyan, " #{spinner} ", :reset,
      :white, "#{state.verb} for #{elapsed}", :reset,
      :faint, " · ", :yellow, state.cost, :reset
    ] ++ action_part

    # Blank line separates scrolling content from sticky status
    [[]] ++ progress_lines ++ [bottom]
  end

  # --- Helpers ---

  defp print_line([]), do: IO.puts("")
  defp print_line(tokens), do: IO.puts(IO.ANSI.format(tokens))

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    if secs == 0, do: "#{mins}m", else: "#{mins}m #{secs}s"
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
  defp tool_icon("browse"), do: "🌐"
  defp tool_icon(_), do: "▶"

  defp tool_label("shell", cmd), do: trunc(cmd, 60)
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
  defp tool_label("browse", url), do: "Browse #{trunc(url, 60)}"
  defp tool_label(name, _), do: name

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
