defmodule Golem.TUI do
  @moduledoc """
  Terminal UI using Owl.LiveScreen for a fixed status area at the bottom
  and Owl.IO.puts for scrolling output above it. No manual ANSI cursor
  manipulation — Owl handles everything.
  """

  require Logger

  @spinner_frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  @spinner_interval 200

  @forge_verbs [
    "Forging", "Hammering", "Smelting", "Tempering", "Quenching",
    "Annealing", "Casting", "Welding", "Shaping", "Refining"
  ]

  # --- Public API ---

  def init_display(run_id, goal) do
    Application.ensure_all_started(:owl)
    Logger.configure(level: :warning)

    puts([Owl.Data.tag("● ", :cyan), Owl.Data.tag("Forge ", [:bright, :white]), Owl.Data.tag(run_id, :faint)])
    puts([Owl.Data.tag("  #{goal}", :faint)])
    puts("")

    initial_state = %{
      progress: [], cost: "$0.0000", action: nil,
      spinner_idx: 0, verb: Enum.random(@forge_verbs),
      started_at: System.monotonic_time(:second)
    }

    :persistent_term.put(:golem_tui_status, initial_state)

    Owl.LiveScreen.add_block(:status,
      state: initial_state,
      render: &render_status/1
    )

    # Start ticker for spinner animation — updates the status block state
    ticker_pid = spawn_link(fn -> ticker_loop() end)
    :persistent_term.put(:golem_tui_ticker, ticker_pid)
    :persistent_term.put(:golem_tui_active, true)
  end

  def stop_display do
    if pid = :persistent_term.get(:golem_tui_ticker, nil) do
      Process.exit(pid, :shutdown)
    end
    :persistent_term.put(:golem_tui_active, false)

    try do
      status = :persistent_term.get(:golem_tui_status, %{})
      started_at = Map.get(status, :started_at, 0)
      cost = Map.get(status, :cost, "$0.0000")
      verb = Map.get(status, :verb, "Forging")
      elapsed = format_duration(System.monotonic_time(:second) - started_at)
      Owl.LiveScreen.flush()
      IO.puts(IO.ANSI.format([:faint, " #{verb} took #{elapsed} · #{cost}", :reset]))
    catch
      _, _ -> :ok
    end

    Logger.configure(level: :info)
  end

  def planning(label \\ "Planning...") do
    puts([Owl.Data.tag("+ ", :yellow), Owl.Data.tag(label, :yellow)])
  end

  def plan_created(plan) do
    phases = Regex.scan(~r/^## /m, plan) |> length()
    steps = Regex.scan(~r/- \[ \]/m, plan) |> length()
    puts([Owl.Data.tag("✓ ", :green), Owl.Data.tag("Plan created ", :green),
          Owl.Data.tag("(#{phases} phases, #{steps} steps)", :faint)])
    puts("")
  end

  def step_header(_step, _max_steps, cost_str) do
    update_status(%{cost: cost_str, action: nil})
  end

  def agent_text(nil), do: :ok
  def agent_text(text) do
    puts("")
    puts([Owl.Data.tag("● ", :cyan), Owl.Data.tag(text, :white)])
  end

  def tool_call(name, detail) do
    update_status(%{action: "#{name} #{detail}"})
  end

  def tool_result(name, detail, result, elapsed_ms, _tokens) do
    elapsed = format_elapsed(elapsed_ms)
    summary = result_oneliner(result)

    puts([Owl.Data.tag("  #{tool_icon(name)} ", :faint),
          Owl.Data.tag(tool_label(name, detail), :white),
          Owl.Data.tag(" (#{elapsed})", :faint)])

    if summary != "" do
      puts([Owl.Data.tag("  └ #{summary}", :faint)])
    end

    update_status(%{action: nil})
  end

  def tool_error(name, detail, error_text) do
    puts([Owl.Data.tag("  ✗ ", :red), Owl.Data.tag(tool_label(name, detail), :red)])
    puts([Owl.Data.tag("  └ #{trunc(error_text, 100)}", [:faint, :red])])
    update_status(%{action: nil})
  end

  def show_diff(path, old_content, new_content) do
    diff_lines = build_diff(path, old_content, new_content)
    if diff_lines != [] do
      added = added_lines(diff_lines)
      removed = removed_lines(diff_lines)
      puts([Owl.Data.tag("    #{Path.basename(path)}: ", :faint),
            Owl.Data.tag("+#{added}", :green), Owl.Data.tag(" / ", :faint),
            Owl.Data.tag("-#{removed}", :red), Owl.Data.tag(" lines", :faint)])
      Enum.each(diff_lines, fn line -> IO.puts(line) end)
      puts("")
    end
  end

  def set_progress(items) do
    update_status(%{progress: items})
  end

  def sub_agent_start(goal) do
    puts([Owl.Data.tag("  ● ", :magenta), Owl.Data.tag("Sub-agent: ", :magenta),
          Owl.Data.tag(trunc(goal, 70), :faint)])
  end

  def sub_agent_result(_goal, steps, success) do
    {icon, color} = if success, do: {"✓", :green}, else: {"✗", :red}
    puts([Owl.Data.tag("  #{icon} ", color), Owl.Data.tag("Sub-agent done ", color),
          Owl.Data.tag("· #{steps} steps", :faint)])
  end

  def replan_start, do: planning("Re-planning with Opus...")
  def replan_done, do: puts([Owl.Data.tag("✓ ", :green), Owl.Data.tag("Plan revised", :green)])

  def show_phase_costs(phase_costs) do
    puts("")
    puts([Owl.Data.tag("  Cost breakdown:", :faint)])
    Enum.each(phase_costs, fn {name, cost} ->
      puts([Owl.Data.tag("    #{name}: ", :white), Owl.Data.tag("$#{cost}", :yellow)])
    end)
  end

  def run_complete(success, summary) do
    update_status(%{action: nil})
    puts("")
    if success do
      puts([Owl.Data.tag("✓ ", :green), Owl.Data.tag("Goal achieved", [:bright, :green])])
    else
      puts([Owl.Data.tag("✗ ", :red), Owl.Data.tag("Goal not achieved", [:bright, :red])])
    end
    puts([Owl.Data.tag("  #{trunc(summary, 120)}", :faint)])
  end

  def run_paused(run_id) do
    puts("")
    puts([Owl.Data.tag("⏸ ", :yellow), Owl.Data.tag("Paused ", :yellow),
          Owl.Data.tag("— resume: ", :faint), Owl.Data.tag("mix golem.resume #{run_id}", :white)])
  end

  def run_error(reason) do
    puts("")
    puts([Owl.Data.tag("✗ Error: #{inspect(reason)}", :red)])
  end

  # Stubs for streaming (disabled — using non-streaming calls)
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

  # --- Status Block Renderer ---

  defp render_status(%{progress: progress, cost: cost, action: action,
                       spinner_idx: idx, verb: verb, started_at: started_at}) do
    spinner = Enum.at(@spinner_frames, idx)
    elapsed = format_duration(System.monotonic_time(:second) - (started_at || 0))

    prog =
      Enum.map(progress, fn item ->
        {icon, color} = case item.status do
          :completed -> {"✓", :green}
          :in_progress -> {"→", :yellow}
          :pending -> {"·", :faint}
        end
        style = if item.status == :pending, do: :faint, else: :white
        [Owl.Data.tag(" [", :faint), Owl.Data.tag(icon, color), Owl.Data.tag("] ", :faint),
         Owl.Data.tag(trunc(item.text, 55), style)]
      end)

    action_part = if action, do: [Owl.Data.tag(" · ", :faint), Owl.Data.tag(trunc(action, 40), :magenta)], else: []

    bottom = [
      Owl.Data.tag(" #{spinner} ", :cyan),
      Owl.Data.tag("#{verb} for #{elapsed}", :white),
      Owl.Data.tag(" · ", :faint),
      Owl.Data.tag(cost, :yellow)
    ] ++ action_part

    (prog ++ [bottom])
    |> Enum.intersperse("\n")
    |> List.flatten()
  end

  defp render_status(_), do: ""

  # --- Helpers ---

  defp puts(data), do: Owl.IO.puts(data)

  defp update_status(changes) do
    try do
      # Store latest state in persistent_term for the ticker to read
      current = :persistent_term.get(:golem_tui_status, %{})
      new_state = Map.merge(current, changes)
      :persistent_term.put(:golem_tui_status, new_state)
      # Update the Owl block with the full state including spinner
      Owl.LiveScreen.update(:status, new_state)
    catch
      _, _ -> :ok
    end
  end

  defp ticker_loop do
    Process.sleep(@spinner_interval)
    try do
      current = :persistent_term.get(:golem_tui_status, %{})
      idx = Map.get(current, :spinner_idx, 0)
      new_idx = rem(idx + 1, length(@spinner_frames))
      new_state = Map.put(current, :spinner_idx, new_idx)
      :persistent_term.put(:golem_tui_status, new_state)
      Owl.LiveScreen.update(:status, new_state)
    catch
      _, _ -> :ok
    end
    ticker_loop()
  end

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

  defp added_lines(diff_lines) do
    Enum.count(diff_lines, &String.contains?(&1, "\e[32m+"))
  end

  defp removed_lines(diff_lines) do
    Enum.count(diff_lines, &String.contains?(&1, "\e[31m-"))
  end

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
