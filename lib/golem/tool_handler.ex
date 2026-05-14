defmodule Golem.ToolHandler do
  @moduledoc """
  Dispatches tool calls to their implementations and formats results.
  """

  require Logger

  @doc """
  Execute a tool call. Returns `{:continue, text}`, `{:done, summary}`,
  `{:think_replan, reasoning}`, etc.

  Wraps dispatch in a try/rescue/catch so a malformed tool input or a
  bug in a single handler can't kill the run — it becomes a
  `{:continue, "[error] …"}` tool_result the model sees on its next
  turn. This is essential when running non-Anthropic providers whose
  tool-input schemas don't always match what our handlers expect
  (e.g. Kimi K2 emitting `"context"` for the `think` tool instead of
  the schema's `"reasoning"`).
  """
  def execute(tool_call, depth \\ 0) do
    dispatch(tool_call, depth)
  rescue
    e ->
      name = tool_name(tool_call)
      Logger.error(
        "Tool #{inspect(name)} raised #{inspect(e.__struct__)}: " <>
          "#{Exception.message(e)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      {:continue,
       "[error] Tool '#{name}' raised #{inspect(e.__struct__)}: #{Exception.message(e)}. " <>
         "Check the tool's input keys against its schema and retry."}
  catch
    kind, reason ->
      name = tool_name(tool_call)
      Logger.error(
        "Tool #{inspect(name)} #{kind} #{inspect(reason)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      {:continue, "[error] Tool '#{name}' failed (#{kind}): #{inspect(reason)}"}
  end

  defp tool_name(%{name: n}) when is_binary(n), do: n
  defp tool_name(%{"name" => n}) when is_binary(n), do: n
  defp tool_name(_), do: "<unknown>"

  defp dispatch(%{name: "shell", input: %{"command" => command}}, _depth) do

    case Golem.Sandbox.exec(command) do
      {:ok, %{output: output, exit_code: 0}} ->
        {:continue, truncate(output, 50_000)}

      {:ok, %{output: output, exit_code: code}} ->
        {:continue, truncate("[exit code #{code}]\n#{output}", 50_000)}

      {:error, {:timeout, partial}} ->
        {:continue, truncate("[command timed out]\n#{partial}", 50_000)}

      {:error, {:stall_timeout, partial}} ->
        stall_s = div(Application.get_env(:golem, :stall_timeout, 120_000), 1000)
        {:continue, truncate("[command stalled — no output for #{stall_s}s, likely waiting for input or running a foreground process. Use & to background long-running processes.]\n#{partial}", 50_000)}

      {:error, reason} ->
        {:continue, "[error] #{inspect(reason)}"}
    end
  end

  defp dispatch(%{name: "write_file", input: %{"path" => path, "content" => content}}, _depth) do

    # Ensure parent directory exists — avoids wasting a step on mkdir -p
    dir = Path.dirname(path)
    if dir != "." and dir != "/" do
      Golem.Sandbox.exec("mkdir -p #{escape(dir)}", timeout: 5_000)
    end

    case Golem.Sandbox.write_file(path, content) do
      :ok ->
        Golem.FileCache.put(path, content)
        {:continue, "File written to #{path}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  defp dispatch(%{name: "read_file", input: %{"path" => path} = input}, _depth) do
    with {:ok, offset} <- coerce_int(Map.get(input, "offset"), "offset"),
         {:ok, limit} <- coerce_int(Map.get(input, "limit"), "limit") do
      # Check cache first (verifies hash against container)
      content =
        case Golem.FileCache.get(path) do
          nil ->
            case Golem.Sandbox.read_file(path) do
              {:ok, c} ->
                Golem.FileCache.put(path, c)
                {:ok, c, false}
              {:error, reason} ->
                {:error, reason}
            end
          c ->
            {:ok, c, true}
        end

      case content do
        {:error, reason} ->
          {:continue, "[error] #{inspect(reason)}"}

        {:ok, full_content, cached} ->
          lines = String.split(full_content, "\n")
          total_lines = length(lines)

          # Apply offset/limit if provided
          {sliced, showing_range} =
            case {offset, limit} do
              {nil, nil} ->
                {full_content, nil}

              {off, lim} ->
                start = max((off || 1) - 1, 0)
                count = lim || total_lines
                selected = lines |> Enum.drop(start) |> Enum.take(count)
                end_line = min(start + count, total_lines)
                {Enum.join(selected, "\n"), "lines #{start + 1}-#{end_line} of #{total_lines}"}
            end

          prefix = if cached, do: "[cached] ", else: ""
          range_info = if showing_range, do: "[#{showing_range}]\n", else: ""

          {body, trunc_notice} = read_file_truncate(sliced, total_lines, start_line_for(offset))
          {:continue, "#{prefix}#{range_info}#{body}#{trunc_notice}"}
      end
    else
      {:error, msg} -> {:continue, "[error] #{msg}"}
    end
  end

  defp dispatch(%{name: "edit_file", input: %{"path" => path, "old_string" => old, "new_string" => new}}, _depth) do

    # Try cache first, fall back to reading from container
    content =
      case Golem.FileCache.get(path) do
        nil ->
          case Golem.Sandbox.read_file(path) do
            {:ok, c} -> c
            {:error, reason} -> {:error, reason}
          end
        c -> c
      end

    case content do
      {:error, reason} ->
        {:continue, "[error] Failed to read #{path}: #{inspect(reason)}"}

      content ->
        case String.split(content, old, parts: 2) do
          [_before, _after] ->
            apply_edit(path, content, old, new)

          [_no_match] ->
            # Check if the edit was already applied (e.g. resume after crash)
            if String.contains?(content, new) do
              Golem.FileCache.put(path, content)
              {:continue, "Edit already applied to #{path} (no change needed)."}
            else
              # Try fuzzy matching: normalize whitespace and retry
              case fuzzy_find(content, old) do
                {:ok, actual_old} ->
                  apply_edit(path, content, actual_old, new)

                :no_match ->
                  line_count = content |> String.split("\n") |> length()
                  hint =
                    case Golem.FileCache.find_context(path, old, 5) do
                      nil -> "\n\nThe file has #{line_count} lines. Use read_file to see the actual content before retrying."
                      ctx -> "\n\nFile has #{line_count} lines. Closest match:\n#{ctx}\n\nDo NOT retry with the same old_string. Read the file first to see the exact content."
                    end

                  {:continue, "[error] old_string not found in #{path}.#{hint}"}
              end
            end
        end
    end
  end

  defp dispatch(%{name: "list_directory", input: %{"path" => path}}, _depth) do

    case Golem.Sandbox.exec("ls -lAh #{escape(path)}", timeout: 60_000) do
      {:ok, %{output: output, exit_code: 0}} -> {:continue, truncate(output, 50_000)}
      {:ok, %{output: output}} -> {:continue, "[error] #{output}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  defp dispatch(%{name: "glob", input: input}, _depth) do
    pattern = Map.fetch!(input, "pattern")
    path = Map.get(input, "path", ".")

    # `-prune` stops descending into vendored/build dirs entirely —
    # without it, find walks every file under node_modules / vendor /
    # .git which routinely pushes a single glob past 60s on a Laravel
    # + Vue codebase. The positive `-path` match then runs only on the
    # remaining tree.
    cmd =
      "cd #{escape(path)} && find . " <>
        "\\( -path '*/node_modules' -o -path '*/vendor' -o -path '*/.git' " <>
        "-o -path '*/_build' -o -path '*/deps' -o -path '*/dist' " <>
        "-o -path '*/.next' -o -path '*/.nuxt' -o -path '*/target' \\) -prune -o " <>
        "-path './#{pattern}' -type f -print 2>/dev/null | sort | head -200"

    case Golem.Sandbox.exec(cmd, timeout: 60_000) do
      {:ok, %{output: output, exit_code: _}} ->
        if output == "" do
          {:continue, "No files matched pattern '#{pattern}' in #{path}"}
        else
          files = output |> String.split("\n") |> Enum.reject(&(&1 == ""))
          count = length(files)
          suffix = if count >= 200, do: "\n(showing first 200 — narrow your pattern)", else: ""
          {:continue, "Found #{count} files:\n#{truncate(output, 30_000)}#{suffix}"}
        end

      {:error, reason} ->
        {:continue, "[error] #{inspect(reason)}"}
    end
  end

  @grep_limit 200

  defp dispatch(%{name: "grep", input: input}, _depth) do
    pattern = Map.fetch!(input, "pattern")
    path = Map.get(input, "path", ".")
    file_glob = Map.get(input, "glob")
    context = Map.get(input, "context", 0)
    offset = Map.get(input, "offset", 0)

    glob_flag = if file_glob, do: " --include='#{file_glob}'", else: ""
    context_flag = if context > 0, do: " -C #{context}", else: ""
    # Skip vendored/build dirs — searching node_modules alone can blow
    # past 60s on a frontend codebase. Same exclusion list as glob.
    exclude_dirs =
      " --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git" <>
        " --exclude-dir=_build --exclude-dir=deps --exclude-dir=dist" <>
        " --exclude-dir=.next --exclude-dir=.nuxt --exclude-dir=target"

    # Get total count first (cheap) so we can show pagination hints
    count_cmd = "grep -rl#{exclude_dirs}#{glob_flag} -- #{escape(pattern)} #{escape(path)} 2>/dev/null | wc -l"
    # Get results with offset + limit
    skip = if offset > 0, do: " | tail -n +#{offset + 1}", else: ""
    results_cmd =
      "grep -rn#{context_flag}#{exclude_dirs}#{glob_flag} -- #{escape(pattern)} #{escape(path)} 2>/dev/null#{skip} | head -#{@grep_limit}"

    # Serialize: the Sandbox is single-threaded so there's no gain from
    # Task.async here — and with the grep handler being one of many
    # things that can run concurrently from the planner, firing two
    # tasks used to deadlock half the batch on :busy before the busy
    # path was made queueing.
    count_result = Golem.Sandbox.exec(count_cmd, timeout: 60_000)
    results_result = Golem.Sandbox.exec(results_cmd, timeout: 60_000)

    total_files =
      case count_result do
        {:ok, %{output: n}} -> n |> String.trim() |> String.to_integer()
        _ -> 0
      end

    case results_result do
      {:ok, %{output: output, exit_code: 0}} when byte_size(output) > 0 ->
        lines = output |> String.split("\n") |> Enum.reject(&(&1 == ""))
        shown = length(lines)

        header =
          if shown >= @grep_limit do
            "Showing #{offset + 1}-#{offset + shown} (#{total_files} files matched, results truncated — use offset: #{offset + shown} to see more)\n"
          else
            ""
          end

        {:continue, header <> truncate(output, 30_000)}

      {:ok, %{output: "", exit_code: 1}} ->
        {:continue, "No matches found for '#{pattern}' in #{path}"}

      {:ok, %{output: output}} ->
        if output == "" do
          {:continue, "No matches found for '#{pattern}' in #{path}"}
        else
          {:continue, truncate(output, 30_000)}
        end

      {:error, reason} ->
        {:continue, "[error] #{inspect(reason)}"}
    end
  end

  defp dispatch(%{name: "web_search", input: %{"query" => query}}, _depth) do

    case Golem.Web.search(query) do
      {:ok, result} -> {:continue, truncate(result, 50_000)}
      {:error, reason} -> {:continue, "[error] Web search failed: #{inspect(reason)}"}
    end
  end

  defp dispatch(%{name: "web_fetch", input: %{"url" => url}}, _depth) do

    case Golem.Web.fetch(url) do
      {:ok, content} -> {:continue, truncate(content, 50_000)}
      {:error, reason} -> {:continue, "[error] Web fetch failed: #{inspect(reason)}"}
    end
  end

  defp dispatch(%{name: "think", input: input}, _depth) do
    # Some non-Anthropic providers (Kimi K2 in particular) emit the
    # reasoning text under alternate keys — "context", "thought",
    # "thoughts". Accept those rather than crash; the tool is just a
    # scratchpad either way.
    reasoning =
      input["reasoning"] || input["context"] || input["thought"] ||
        input["thoughts"] || ""

    replan = Map.get(input, "request_replan", false)

    Golem.Events.emit(:thought, %{
      request_replan: replan,
      reasoning: String.slice(reasoning, 0, 2000)
    })

    if replan do
      {:think_replan, reasoning}
    else
      {:continue, reasoning}
    end
  end

  defp dispatch(%{name: "browse", input: %{"url" => url}}, _depth) do

    # Kill any existing Firefox, then open the URL
    Golem.Sandbox.exec("DISPLAY=:99 pkill -f firefox 2>/dev/null; sleep 0.5", timeout: 5_000)
    Golem.Sandbox.exec("DISPLAY=:99 firefox --no-remote '#{url}' &", timeout: 5_000)

    # Wait for page to load
    Process.sleep(4_000)

    # Take screenshot
    case Golem.Screenshot.capture() do
      {:ok, %{path: path, base64: base64}} ->
        {:continue_with_image, %{text: "Browsed #{url} — screenshot saved to #{path}", base64: base64}}

      {:error, reason} ->
        {:continue, "[error] Screenshot failed after browsing #{url}: #{inspect(reason)}"}
    end
  end

  defp dispatch(%{name: "update_progress", input: %{"items" => items}}, depth) do
    # Handle items sent as a JSON string instead of a parsed list
    items =
      case items do
        s when is_binary(s) ->
          case Jason.decode(s) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end
        list when is_list(list) -> list
        _ -> []
      end

    parsed =
      Enum.map(items, fn item ->
        status =
          case Map.get(item, "status", "pending") do
            # Agent says "completed" → :done (unverified). Only the system
            # sets :completed (verified) after done + verification passes.
            s when s in ["completed", "complete", "done"] -> :done
            s when s in ["in_progress", "in-progress", "working", "active"] -> :in_progress
            _ -> :pending
          end

        %{text: Map.get(item, "text", ""), status: status}
      end)

    # Merge with persisted state to prevent regressions:
    # - :completed items stay completed (system-verified, from verification or resume)
    # - :done items don't regress to in_progress or pending (compaction safety)
    # - :in_progress items don't regress to pending (compaction safety)
    previous = :persistent_term.get(:golem_progress, [])
    preserved = Map.new(previous, &{&1.text, &1.status})

    status_rank = %{pending: 0, in_progress: 1, done: 2, completed: 3}

    merged =
      Enum.map(parsed, fn item ->
        prev_status = Map.get(preserved, item.text)
        if prev_status && status_rank[prev_status] > status_rank[item.status] do
          %{item | status: prev_status}
        else
          item
        end
      end)

    # Run verification for items that just transitioned to :done
    verify_commands = :persistent_term.get(:golem_verify_commands, %{})

    {merged, unverified} =
      if depth == 0 do
        Enum.map_reduce(merged, [], fn item, unverified ->
          newly_done = item.status == :done and Map.get(preserved, item.text) not in [:done, :completed]

          if newly_done do
            case Golem.PlanParser.find_verify_command(verify_commands, item.text) do
              nil ->
                # No verify command — flag as unverified so we can warn the agent
                {item, [item.text | unverified]}
              cmd ->
                case Golem.Sandbox.exec(cmd, timeout: 10_000, stall_timeout: :infinity) do
                  {:ok, %{exit_code: 0}} ->
                    {%{item | status: :completed}, unverified}
                  _ ->
                    {item, [item.text | unverified]}
                end
            end
          else
            {item, unverified}
          end
        end)
      else
        {merged, []}
      end

    done = Enum.count(merged, &(&1.status in [:done, :completed]))
    total = length(merged)

    # Only update TUI and persistent state for top-level agent
    if depth == 0 do
      Golem.Output.current().set_progress(merged)
      :persistent_term.put(:golem_progress, merged)
    end

    # Warn agent about unverified steps
    verification_warning =
      if unverified != [] do
        steps = Enum.map_join(Enum.reverse(unverified), "\n", &"- #{&1}")
        "\n\n[System] The following steps were marked completed but have NOT been verified:\n#{steps}\nRun the build and relevant tests NOW to verify these steps before continuing."
      else
        ""
      end
    {:continue, "Progress updated (#{done}/#{total} completed).#{verification_warning}"}
  end

  # Per-batch timeout for parallel sub-agents. With a 50-step cap and
  # a 2-minute stall timeout per shell, a worst-case agent runs about
  # 30 minutes; doubling that keeps a single hung agent from
  # indefinitely blocking the parent (which used to be `:infinity`).
  @parallel_sub_agents_timeout_ms 60 * 60 * 1000

  defp dispatch(%{name: "parallel_sub_agents", input: %{"agents" => agents}}, depth) do
    parent_state = Process.get(:golem_parent_state)
    # The parent process owns the events.jsonl run id in its process
    # dict. Spawned Tasks start with an empty dict, so we capture the
    # value here and re-seed it inside each Task — otherwise sub-agent
    # events are silently dropped (Golem.Events.emit/2 returns :ok when
    # current_run() is nil).
    parent_run_id = Golem.Events.current_run()

    # Split agents into cached hits and ones that need to run
    {cached, to_run} =
      Enum.split_with(agents, fn agent ->
        match?({:hit, _}, find_completed_sub_agent(Map.fetch!(agent, "goal")))
      end)

    if cached != [] do
    end

    # Run only the uncached agents
    run_results =
      if to_run != [] do
        tasks =
          Enum.map(to_run, fn agent ->
            goal = Map.fetch!(agent, "goal")
            context = Map.get(agent, "context", "") |> enrich_sub_agent_context(goal)
            Task.async(fn ->
              if parent_run_id, do: Golem.Events.set_run(parent_run_id)

              # Buffered output: each Task accumulates its tool calls in
              # its own process dict, then flushes the whole block when
              # the sub-agent completes. Streaming would interleave 5+
              # concurrent agents' output under one header.
              Golem.Runner.run_sub_agent(goal, context, depth, parent_state, buffered: true)
            end)
          end)

        # Wait with a timeout. Tasks still running at the deadline are
        # brutally killed — better to surface a hung sub-agent as an
        # error than block the entire parent run forever.
        results =
          tasks
          |> Task.yield_many(@parallel_sub_agents_timeout_ms)
          |> Enum.map(fn {task, outcome} ->
            case outcome do
              {:ok, value} ->
                value

              {:exit, reason} ->
                {:error, {:task_exit, reason}}

              nil ->
                Task.shutdown(task, :brutal_kill)
                {:error, :timeout}
            end
          end)

        Enum.each(results, &merge_sub_agent_costs/1)

        # Record successful results
        Enum.zip(to_run, results)
        |> Enum.each(fn {agent, result} ->
          case result do
            {:ok, %{success: true, summary: s} = r} ->
              files = format_file_list(r)
              record_completed_sub_agent(Map.fetch!(agent, "goal"), "✓ #{s}#{files}")
            _ -> :ok
          end
        end)

        Enum.zip(to_run, results)
      else
        []
      end

    # Build combined summary
    all_summaries =
      Enum.map(cached, fn agent ->
        goal = Map.fetch!(agent, "goal")
        {:hit, prev} = find_completed_sub_agent(goal)
        "✓ #{goal}: [cached] #{String.slice(prev, 0, 100)}"
      end) ++
      Enum.map(run_results, fn {agent, result} ->
        goal = Map.get(agent, "goal", "unknown")
        case result do
          {:ok, %{success: true, summary: s}} -> "✓ #{goal}: #{s}"
          {:ok, %{success: false, summary: s}} -> "✗ #{goal}: #{s}"
          {:error, reason} -> "✗ #{goal}: error — #{inspect(reason)}"
        end
      end)

    succeeded = length(cached) + Enum.count(run_results, fn {_, r} -> match?({:ok, %{success: true}}, r) end)
    total = length(cached) + length(to_run)
    {:continue, "#{succeeded}/#{total} sub-agents succeeded:\n#{Enum.join(all_summaries, "\n")}"}
  end

  defp dispatch(%{name: "screenshot", input: _input}, _depth) do

    case Golem.Screenshot.capture() do
      {:ok, %{path: path, base64: base64}} ->
        {:continue_with_image, %{text: "Screenshot saved to #{path}", base64: base64}}

      {:error, reason} ->
        {:continue, "[error] Screenshot failed: #{inspect(reason)}"}
    end
  end

  defp dispatch(%{name: "gui_click", input: %{"x" => x, "y" => y}}, _depth) do

    case Golem.Sandbox.exec("DISPLAY=:99 xdotool mousemove #{x} #{y} click 1", timeout: 5_000) do
      {:ok, %{exit_code: 0}} -> {:continue, "Clicked at (#{x}, #{y})"}
      {:ok, %{output: out}} -> {:continue, "[error] #{out}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  defp dispatch(%{name: "gui_type", input: %{"text" => text}}, _depth) do
    # Use xdotool type with --clearmodifiers to avoid modifier key issues
    escaped = String.replace(text, "'", "'\\''")

    case Golem.Sandbox.exec("DISPLAY=:99 xdotool type --clearmodifiers '#{escaped}'", timeout: 10_000) do
      {:ok, %{exit_code: 0}} -> {:continue, "Typed text"}
      {:ok, %{output: out}} -> {:continue, "[error] #{out}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  defp dispatch(%{name: "gui_key", input: %{"key" => key}}, _depth) do

    case Golem.Sandbox.exec("DISPLAY=:99 xdotool key --clearmodifiers #{key}", timeout: 5_000) do
      {:ok, %{exit_code: 0}} -> {:continue, "Pressed #{key}"}
      {:ok, %{output: out}} -> {:continue, "[error] #{out}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  defp dispatch(%{name: "gui_scroll", input: input}, _depth) do
    direction = Map.get(input, "direction", "down")
    clicks = Map.get(input, "clicks", 3)
    button = if direction == "up", do: 4, else: 5

    cmds = Enum.map_join(1..clicks, " && ", fn _ -> "DISPLAY=:99 xdotool click #{button}" end)

    case Golem.Sandbox.exec(cmds, timeout: 5_000) do
      {:ok, %{exit_code: 0}} -> {:continue, "Scrolled #{direction} #{clicks} clicks"}
      {:ok, %{output: out}} -> {:continue, "[error] #{out}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  defp dispatch(%{name: "sub_agent", input: input}, depth) do
    goal = Map.fetch!(input, "goal")
    context = Map.get(input, "context", "")
    parent_state = Process.get(:golem_parent_state)

    # Check if a similar sub-agent already ran successfully
    case find_completed_sub_agent(goal) do
      {:hit, cached} ->
        Golem.Events.emit(:sub_agent_skipped, %{goal: String.slice(goal, 0, 500)})
        {:continue, cached}

      :miss ->
        context = enrich_sub_agent_context(context, goal)

        result = Golem.Runner.run_sub_agent(goal, context, depth, parent_state)
        merge_sub_agent_costs(result)

        case result do
          {:ok, %{success: true, summary: summary} = r} ->
            invalidate_sub_agent_files(r)
            files = format_file_list(r)
            response = "Sub-agent completed successfully: #{summary}#{files}" <> stale_file_warning(r)
            record_completed_sub_agent(goal, response)
            {:continue, response}

          {:ok, %{success: false, summary: summary} = r} ->
            invalidate_sub_agent_files(r)
            files = format_file_list(r)
            {:continue, "Sub-agent did not achieve its goal: #{summary}#{files}" <> stale_file_warning(r)}

          {:error, :max_steps_reached} ->
            {:continue, "Sub-agent hit its step limit without finishing. The sub-task may be partially complete — read the files it created with `read_file` before making changes."}

          {:error, :max_steps_reached, _step} ->
            {:continue, "Sub-agent hit its step limit without finishing. The sub-task may be partially complete — read the files it created with `read_file` before making changes."}

          {:error, reason} ->
            {:continue, "[error] Sub-agent failed: #{inspect(reason)}"}

          {:error, reason, _step} ->
            {:continue, "[error] Sub-agent failed: #{inspect(reason)}"}
        end
    end
  end

  defp dispatch(%{name: "done", input: input}, _depth) do
    success = Map.get(input, "success", false)
    summary = Map.get(input, "summary", "No summary provided")
    {:done, %{success: success, summary: summary}}
  end

  # MCP tools — namespaced as mcp_{server}_{tool}
  defp dispatch(%{name: "mcp_" <> _ = name, input: input}, _depth) do

    case Golem.MCP.call_tool(name, input) do
      {:ok, text} -> {:continue, truncate(text, 50_000)}
      {:error, reason} -> {:continue, "[MCP error] #{inspect(reason)}"}
    end
  end

  defp dispatch(%{name: name}, _depth) do
    Logger.warning("  [unknown tool] #{name}")
    {:continue, "[error] Unknown tool: #{name}"}
  end

  # The model occasionally passes integer-typed args as strings or
  # bracket-wrapped strings (e.g. "[2900]"). Coerce gracefully and
  # surface a useful error back to the agent instead of crashing the
  # runner with an ArithmeticError downstream.
  defp coerce_int(nil, _name), do: {:ok, nil}
  defp coerce_int(n, _name) when is_integer(n), do: {:ok, n}

  defp coerce_int(s, name) when is_binary(s) do
    trimmed = s |> String.trim() |> String.trim_leading("[") |> String.trim_trailing("]")

    case Integer.parse(trimmed) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "#{name} must be an integer, got #{inspect(s)}"}
    end
  end

  defp coerce_int(other, name),
    do: {:error, "#{name} must be an integer, got #{inspect(other)}"}

  # --- Sub-Agent File Invalidation ---

  # After a sub-agent modifies files, invalidate the parent's cached
  # knowledge of those files so it doesn't use stale content in edit_file.
  defp invalidate_sub_agent_files(%{files: files}) when is_list(files) do
    Enum.each(files, &Golem.FileCache.delete/1)
  end

  defp invalidate_sub_agent_files(_), do: :ok

  defp stale_file_warning(%{files: files}) when is_list(files) and files != [] do
    """

    WARNING: The following files were created or modified by the sub-agent. \
    Any file content you saw BEFORE this sub-agent ran is now STALE. \
    You MUST use `read_file` before using `edit_file` on any of these files — \
    your old_string will not match if you use memorized content.

    Modified files: #{Enum.join(files, ", ")}
    """
  end

  defp stale_file_warning(_), do: ""

  # --- Sub-Agent Deduplication ---

  # Track completed sub-agent goals to prevent re-running the same work
  # after verification rejection. Uses fuzzy matching since the agent may
  # rephrase the goal slightly on retry.

  defp find_completed_sub_agent(goal) do
    completed = :persistent_term.get(:golem_completed_sub_agents, %{})
    normalized = normalize_goal(goal)

    # Exact match first
    case Map.get(completed, normalized) do
      nil ->
        # Fuzzy: check if any completed goal shares >60% of words
        Enum.find_value(completed, :miss, fn {prev_goal, result} ->
          if goal_similarity(normalized, prev_goal) > 0.6 do
            {:hit, result}
          end
        end)

      result ->
        {:hit, result}
    end
  end

  defp record_completed_sub_agent(goal, result) do
    completed = :persistent_term.get(:golem_completed_sub_agents, %{})
    :persistent_term.put(:golem_completed_sub_agents, Map.put(completed, normalize_goal(goal), result))
  end

  defp normalize_goal(goal) do
    goal
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp goal_similarity(a, b) do
    words_a = MapSet.new(String.split(a))
    words_b = MapSet.new(String.split(b))
    intersection = MapSet.intersection(words_a, words_b) |> MapSet.size()
    union = MapSet.union(words_a, words_b) |> MapSet.size()
    if union == 0, do: 0.0, else: intersection / union
  end

  # --- Sub-Agent Context Enrichment ---

  # Extract file paths from the goal text and include directory listings
  # so sub-agents know what exists before they start writing.
  defp enrich_sub_agent_context(context, goal) do
    # Find absolute paths mentioned in the goal
    paths =
      Regex.scan(~r{(/home/\S+?)(?:[\s,\)\]\}]|$)}, goal)
      |> Enum.map(fn [_, path] -> path end)
      |> Enum.uniq()

    # Get unique directories
    dirs =
      paths
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == "/" or &1 == "."))

    if dirs == [] do
      context
    else
      listings =
        dirs
        |> Enum.map(fn dir ->
          case Golem.Sandbox.exec("ls -la #{dir} 2>/dev/null | head -30", timeout: 5_000) do
            {:ok, %{exit_code: 0, output: output}} when byte_size(output) > 0 ->
              "### #{dir}\n```\n#{String.trim(output)}\n```"
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")

      if listings != "" do
        context <> "\n\n## Directory context (auto-generated)\n\nThese are the files that already exist in the directories you'll be working in. Study them before writing new files.\n\n#{listings}"
      else
        context
      end
    end
  end

  # --- Cost Merging ---

  # Merge sub-agent costs into the parent's running total via process dictionary.
  # The parent runner reads this back after tool execution.
  defp merge_sub_agent_costs({:ok, %{costs: sub_costs}}) do
    existing = Process.get(:golem_sub_agent_costs, 0.0)
    sub_total = Map.get(sub_costs, :total_dollars, 0.0)
    Process.put(:golem_sub_agent_costs, existing + sub_total)
  end

  defp merge_sub_agent_costs(_), do: :ok

  # --- Edit Helpers ---

  defp apply_edit(path, content, old, new) do
    updated = String.replace(content, old, new, global: false)

    case Golem.Sandbox.write_file(path, updated) do
      :ok ->
        Golem.FileCache.put(path, updated)
        Golem.Output.current().show_diff(path, content, updated)
        {:continue, "Edit applied to #{path}"}

      {:error, reason} ->
        {:continue, "[error] Failed to write: #{inspect(reason)}"}
    end
  end

  # Try to find old_string in content using whitespace normalization.
  # Handles: trailing whitespace differences, tab/space mismatches,
  # and minor indentation shifts.
  defp fuzzy_find(content, old_string) do
    normalized_old = normalize_ws(old_string)
    old_lines = String.split(normalized_old, "\n")
    old_line_count = length(old_lines)

    content_lines = String.split(content, "\n")

    # Slide a window of old_line_count lines over content_lines
    match_idx =
      content_lines
      |> Enum.with_index()
      |> Enum.find_value(fn {_line, idx} ->
        window = Enum.slice(content_lines, idx, old_line_count)

        if length(window) == old_line_count and normalize_ws(Enum.join(window, "\n")) == normalized_old do
          idx
        end
      end)

    if match_idx do
      actual = content_lines |> Enum.slice(match_idx, old_line_count) |> Enum.join("\n")
      {:ok, actual}
    else
      :no_match
    end
  end

  # Normalize whitespace for fuzzy comparison:
  # - Strip trailing whitespace from each line
  # - Collapse runs of spaces/tabs to a single space (preserves leading indent structure)
  defp normalize_ws(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      line
      |> String.trim_trailing()
      |> String.replace(~r/\t/, "  ")
    end)
    |> Enum.join("\n")
  end

  defp format_file_list(%{files: files}) when is_list(files) and files != [] do
    list = Enum.map_join(files, "\n", &"  - #{&1}")
    "\n\nFiles created/modified by sub-agent:\n#{list}"
  end

  defp format_file_list(_), do: ""

  defp escape(str), do: "'#{String.replace(str, "'", "'\\''")}'"

  @max_result_chars 30_000
  @preview_size 2_000
  @persist_dir "/home/agent/.golem/tool-results"

  @doc """
  Handle large tool results. If text exceeds @max_result_chars, persist the full
  output to disk in the container and return a preview with a file path reference.
  The agent can `read_file` the persisted output if it needs the full content.
  """
  def truncate_result({:continue, text}) when is_binary(text) and byte_size(text) > @max_result_chars do
    {:continue, persist_and_preview(text)}
  end

  def truncate_result({:continue_with_image, %{text: text} = data}) when is_binary(text) and byte_size(text) > @max_result_chars do
    {:continue_with_image, %{data | text: persist_and_preview(text)}}
  end

  def truncate_result(other), do: other

  # Simple truncation for per-tool size hints (keeps tail).
  # The central truncate_result/1 handles persist-to-disk for anything still too large.
  defp truncate(text, max) when byte_size(text) > max do
    "[truncated to #{max} bytes]\n..." <>
      binary_part(text, byte_size(text) - max, max)
  end

  defp truncate(text, _max), do: text

  # Truncate a read_file body at 50KB and append an explicit notice the
  # model can act on — silent truncation causes the agent to think it saw
  # the whole file when it didn't.
  defp read_file_truncate(text, total_lines, start_line) when byte_size(text) > 50_000 do
    kept = binary_part(text, 0, 50_000)
    shown_lines = kept |> String.split("\n") |> length()
    last_shown = start_line + shown_lines - 1
    notice = "\n\n[Truncated — file has #{total_lines} lines, showing #{start_line}-#{last_shown} (first 50KB). Use `offset` and `limit` to read more, or `grep` to locate what you need.]"
    {kept, notice}
  end
  defp read_file_truncate(text, _total_lines, _start_line), do: {text, ""}

  defp start_line_for(nil), do: 1
  defp start_line_for(off) when is_integer(off) and off > 0, do: off
  defp start_line_for(_), do: 1

  defp persist_and_preview(text) do
    total = byte_size(text)
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    path = "#{@persist_dir}/#{id}.txt"

    # Write full output to container filesystem
    Golem.Sandbox.exec("mkdir -p #{@persist_dir}", timeout: 5_000)

    case Golem.Sandbox.write_file(path, text) do
      :ok ->
        preview = binary_part(text, 0, min(@preview_size, total))
        "[Output too large (#{total} bytes). Full output saved to: #{path}]\n\nPreview (first #{@preview_size} bytes):\n#{preview}"

      {:error, _reason} ->
        # Fall back to head+tail truncation if persistence fails
        head = binary_part(text, 0, min(@preview_size, total))
        tail = binary_part(text, total - min(@preview_size, total), min(@preview_size, total))
        "#{head}\n\n[... truncated #{total - @preview_size * 2} bytes ...]\n\n#{tail}"
    end
  end
end
