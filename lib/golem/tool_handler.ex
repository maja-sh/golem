defmodule Golem.ToolHandler do
  @moduledoc """
  Dispatches tool calls to their implementations and formats results.
  """

  require Logger

  @doc """
  Execute a tool call. Returns {:continue, result_text}, {:done, summary}, etc.
  Depth is passed through for sub-agent spawning.
  """
  def execute(tool_call, depth \\ 0)

  def execute(%{name: "shell", input: %{"command" => command}}, _depth) do
    Logger.info("  [shell] #{String.slice(command, 0, 200)}")

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

  def execute(%{name: "write_file", input: %{"path" => path, "content" => content}}, _depth) do
    Logger.info("  [write_file] #{path} (#{byte_size(content)} bytes)")

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

  def execute(%{name: "read_file", input: %{"path" => path} = input}, _depth) do
    offset = Map.get(input, "offset")
    limit = Map.get(input, "limit")
    Logger.info("  [read_file] #{path}#{if offset, do: " offset=#{offset}"}#{if limit, do: " limit=#{limit}"}")

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
          Logger.info("  [read_file] cache hit for #{path}")
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

        {:continue, "#{prefix}#{range_info}#{truncate(sliced, 50_000)}"}
    end
  end

  def execute(%{name: "edit_file", input: %{"path" => path, "old_string" => old, "new_string" => new}}, _depth) do
    Logger.info("  [edit_file] #{path}")

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
                  Logger.info("  [edit_file] fuzzy match succeeded for #{path}")
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

  def execute(%{name: "list_directory", input: %{"path" => path}}, _depth) do
    Logger.info("  [list_directory] #{path}")

    case Golem.Sandbox.exec("ls -lAh #{escape(path)}", timeout: 10_000) do
      {:ok, %{output: output, exit_code: 0}} -> {:continue, truncate(output, 50_000)}
      {:ok, %{output: output}} -> {:continue, "[error] #{output}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "glob", input: input}, _depth) do
    pattern = Map.fetch!(input, "pattern")
    path = Map.get(input, "path", ".")
    Logger.info("  [glob] #{pattern} in #{path}")

    # Use find with -path for glob matching, or shell globstar
    cmd = "cd #{escape(path)} && find . -path './#{pattern}' -type f 2>/dev/null | sort | head -200"

    case Golem.Sandbox.exec(cmd, timeout: 15_000) do
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

  def execute(%{name: "grep", input: input}, _depth) do
    pattern = Map.fetch!(input, "pattern")
    path = Map.get(input, "path", ".")
    file_glob = Map.get(input, "glob")
    context = Map.get(input, "context", 0)
    offset = Map.get(input, "offset", 0)
    Logger.info("  [grep] '#{pattern}' in #{path}")

    glob_flag = if file_glob, do: " --include='#{file_glob}'", else: ""
    context_flag = if context > 0, do: " -C #{context}", else: ""

    # Get total count first (cheap) so we can show pagination hints
    count_cmd = "grep -rl#{glob_flag} -- #{escape(pattern)} #{escape(path)} 2>/dev/null | wc -l"
    # Get results with offset + limit
    skip = if offset > 0, do: " | tail -n +#{offset + 1}", else: ""
    results_cmd = "grep -rn#{context_flag}#{glob_flag} -- #{escape(pattern)} #{escape(path)} 2>/dev/null#{skip} | head -#{@grep_limit}"

    count_task = Task.async(fn -> Golem.Sandbox.exec(count_cmd, timeout: 15_000) end)
    results_task = Task.async(fn -> Golem.Sandbox.exec(results_cmd, timeout: 15_000) end)

    [count_result, results_result] = Task.await_many([count_task, results_task], :infinity)

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

  def execute(%{name: "web_search", input: %{"query" => query}}, _depth) do
    Logger.info("  [web_search] #{query}")

    case Golem.Web.search(query) do
      {:ok, result} -> {:continue, truncate(result, 50_000)}
      {:error, reason} -> {:continue, "[error] Web search failed: #{inspect(reason)}"}
    end
  end

  def execute(%{name: "web_fetch", input: %{"url" => url}}, _depth) do
    Logger.info("  [web_fetch] #{url}")

    case Golem.Web.fetch(url) do
      {:ok, content} -> {:continue, truncate(content, 50_000)}
      {:error, reason} -> {:continue, "[error] Web fetch failed: #{inspect(reason)}"}
    end
  end

  def execute(%{name: "think", input: input}, _depth) do
    reasoning = Map.fetch!(input, "reasoning")
    replan = Map.get(input, "request_replan", false)
    Logger.info("  [think#{if replan, do: " + replan", else: ""}] #{String.slice(reasoning, 0, 500)}")

    if replan do
      {:think_replan, reasoning}
    else
      {:continue, reasoning}
    end
  end

  def execute(%{name: "ask_user", input: %{"question" => question}}, _depth) do
    Logger.info("  [ask_user] #{String.slice(question, 0, 200)}")

    # Get run_id from the process dictionary (set by the runner)
    run_id = Process.get(:golem_run_id, "unknown")

    case Golem.Discord.ask(question, run_id) do
      {:ok, reply} ->
        {:continue, "User replied: #{reply}"}

      {:error, reason} ->
        Logger.error("  [ask_user] Discord error: #{inspect(reason)}")
        {:continue, "[error] Could not reach the user via Discord. Make your best judgment and continue."}
    end
  end

  def execute(%{name: "browse", input: %{"url" => url}}, _depth) do
    Logger.info("  [browse] #{url}")

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

  def execute(%{name: "update_progress", input: %{"items" => items}}, depth) do
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

    merged =
      if depth == 0 and verify_commands != %{} do
        Enum.map(merged, fn item ->
          newly_done = item.status == :done and Map.get(preserved, item.text) not in [:done, :completed]

          if newly_done do
            case Golem.PlanParser.find_verify_command(verify_commands, item.text) do
              nil -> item
              cmd ->
                case Golem.Sandbox.exec(cmd, timeout: 10_000, stall_timeout: :infinity) do
                  {:ok, %{exit_code: 0}} ->
                    Logger.info("  [verify] ✓ #{item.text}")
                    %{item | status: :completed}
                  _ ->
                    Logger.info("  [verify] ✗ #{item.text}")
                    item
                end
            end
          else
            item
          end
        end)
      else
        merged
      end

    done = Enum.count(merged, &(&1.status in [:done, :completed]))
    total = length(merged)
    Logger.info("  [update_progress] #{done}/#{total} completed")

    # Only update TUI and persistent state for top-level agent
    if depth == 0 do
      Golem.Output.current().set_progress(merged)
      :persistent_term.put(:golem_progress, merged)
    end
    {:continue, "Progress updated (#{done}/#{total} completed)."}
  end

  def execute(%{name: "parallel_sub_agents", input: %{"agents" => agents}}, depth) do
    count = length(agents)
    parent_state = Process.get(:golem_parent_state)
    Logger.info("  [parallel_sub_agents] #{count} agents")

    # Spawn all sub-agents concurrently
    tasks =
      Enum.map(agents, fn agent ->
        goal = Map.fetch!(agent, "goal")
        context = Map.get(agent, "context", "")
        Task.async(fn -> Golem.Runner.run_sub_agent(goal, context, depth, parent_state) end)
      end)

    # Await all results (generous timeout — sub-agents can take a while)
    results = Task.await_many(tasks, :infinity)

    # Format results summary
    summaries =
      results
      |> Enum.zip(agents)
      |> Enum.map(fn {result, agent} ->
        goal = Map.get(agent, "goal", "unknown")
        case result do
          {:ok, %{success: true, summary: s}} -> "✓ #{goal}: #{s}"
          {:ok, %{success: false, summary: s}} -> "✗ #{goal}: #{s}"
          {:error, reason} -> "✗ #{goal}: error — #{inspect(reason)}"
        end
      end)
      |> Enum.join("\n")

    succeeded = Enum.count(results, &match?({:ok, %{success: true}}, &1))
    {:continue, "#{succeeded}/#{count} sub-agents succeeded:\n#{summaries}"}
  end

  def execute(%{name: "screenshot", input: _input}, _depth) do
    Logger.info("  [screenshot]")

    case Golem.Screenshot.capture() do
      {:ok, %{path: path, base64: base64}} ->
        {:continue_with_image, %{text: "Screenshot saved to #{path}", base64: base64}}

      {:error, reason} ->
        {:continue, "[error] Screenshot failed: #{inspect(reason)}"}
    end
  end

  def execute(%{name: "gui_click", input: %{"x" => x, "y" => y}}, _depth) do
    Logger.info("  [gui_click] #{x},#{y}")

    case Golem.Sandbox.exec("DISPLAY=:99 xdotool mousemove #{x} #{y} click 1", timeout: 5_000) do
      {:ok, %{exit_code: 0}} -> {:continue, "Clicked at (#{x}, #{y})"}
      {:ok, %{output: out}} -> {:continue, "[error] #{out}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "gui_type", input: %{"text" => text}}, _depth) do
    Logger.info("  [gui_type] #{String.slice(text, 0, 50)}")
    # Use xdotool type with --clearmodifiers to avoid modifier key issues
    escaped = String.replace(text, "'", "'\\''")

    case Golem.Sandbox.exec("DISPLAY=:99 xdotool type --clearmodifiers '#{escaped}'", timeout: 10_000) do
      {:ok, %{exit_code: 0}} -> {:continue, "Typed text"}
      {:ok, %{output: out}} -> {:continue, "[error] #{out}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "gui_key", input: %{"key" => key}}, _depth) do
    Logger.info("  [gui_key] #{key}")

    case Golem.Sandbox.exec("DISPLAY=:99 xdotool key --clearmodifiers #{key}", timeout: 5_000) do
      {:ok, %{exit_code: 0}} -> {:continue, "Pressed #{key}"}
      {:ok, %{output: out}} -> {:continue, "[error] #{out}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "gui_scroll", input: input}, _depth) do
    direction = Map.get(input, "direction", "down")
    clicks = Map.get(input, "clicks", 3)
    button = if direction == "up", do: 4, else: 5
    Logger.info("  [gui_scroll] #{direction} #{clicks}")

    cmds = Enum.map_join(1..clicks, " && ", fn _ -> "DISPLAY=:99 xdotool click #{button}" end)

    case Golem.Sandbox.exec(cmds, timeout: 5_000) do
      {:ok, %{exit_code: 0}} -> {:continue, "Scrolled #{direction} #{clicks} clicks"}
      {:ok, %{output: out}} -> {:continue, "[error] #{out}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "sub_agent", input: input}, depth) do
    goal = Map.fetch!(input, "goal")
    context = Map.get(input, "context", "")
    parent_state = Process.get(:golem_parent_state)
    Logger.info("  [sub_agent] depth=#{depth + 1} — #{String.slice(goal, 0, 200)}")

    case Golem.Runner.run_sub_agent(goal, context, depth, parent_state) do
      {:ok, %{success: true, summary: summary} = result} ->
        files = format_file_list(result)
        {:continue, "Sub-agent completed successfully: #{summary}#{files}\n\nIMPORTANT: Do NOT rewrite these files — read them first with `read_file` if you need to understand or modify what the sub-agent produced."}

      {:ok, %{success: false, summary: summary} = result} ->
        files = format_file_list(result)
        {:continue, "Sub-agent did not achieve its goal: #{summary}#{files}\n\nRead these files with `read_file` before making changes."}

      {:error, :max_steps_reached} ->
        {:continue, "Sub-agent hit its step limit without finishing. The sub-task may be partially complete — read the files it created with `read_file` before making changes."}

      {:error, reason} ->
        {:continue, "[error] Sub-agent failed: #{inspect(reason)}"}
    end
  end

  def execute(%{name: "done", input: input}, _depth) do
    success = Map.get(input, "success", false)
    summary = Map.get(input, "summary", "No summary provided")
    Logger.info("  [done] success=#{success} — #{summary}")
    {:done, %{success: success, summary: summary}}
  end

  def execute(%{name: name}, _depth) do
    Logger.warning("  [unknown tool] #{name}")
    {:continue, "[error] Unknown tool: #{name}"}
  end

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
