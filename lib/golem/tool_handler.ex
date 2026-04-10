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

      {:error, reason} ->
        {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "write_file", input: %{"path" => path, "content" => content}}, _depth) do
    Logger.info("  [write_file] #{path} (#{byte_size(content)} bytes)")

    case Golem.Sandbox.write_file(path, content) do
      :ok ->
        Golem.FileCache.put(path, content)
        {:continue, "File written to #{path}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "read_file", input: %{"path" => path}}, _depth) do
    Logger.info("  [read_file] #{path}")

    # Check cache first (verifies hash against container)
    case Golem.FileCache.get(path) do
      nil ->
        case Golem.Sandbox.read_file(path) do
          {:ok, content} ->
            Golem.FileCache.put(path, content)
            {:continue, truncate(content, 50_000)}
          {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
        end
      content ->
        Logger.info("  [read_file] cache hit for #{path}")
        {:continue, "[cached — you've already read/written this file]\n#{truncate(content, 50_000)}"}
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
            updated = String.replace(content, old, new, global: false)

            case Golem.Sandbox.write_file(path, updated) do
              :ok ->
                Golem.FileCache.put(path, updated)
                # show_diff prints the diff AND the edit summary atomically
                Golem.TUI.show_diff(path, content, updated)
                {:continue, "Edit applied to #{path}"}
              {:error, reason} ->
                {:continue, "[error] Failed to write: #{inspect(reason)}"}
            end

          [_no_match] ->
            # Check if the edit was already applied (e.g. resume after crash)
            if String.contains?(content, new) do
              Golem.FileCache.put(path, content)
              {:continue, "Edit already applied to #{path} (no change needed)."}
            else
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
    cmd = "cd #{escape(path)} && find . -path './#{pattern}' -type f 2>/dev/null | head -200 | sort"

    case Golem.Sandbox.exec(cmd, timeout: 15_000) do
      {:ok, %{output: output, exit_code: _}} ->
        if output == "" do
          {:continue, "No files matched pattern '#{pattern}' in #{path}"}
        else
          count = output |> String.split("\n") |> length()
          {:continue, "Found #{count} files:\n#{truncate(output, 50_000)}"}
        end

      {:error, reason} ->
        {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "grep", input: input}, _depth) do
    pattern = Map.fetch!(input, "pattern")
    path = Map.get(input, "path", ".")
    file_glob = Map.get(input, "glob")
    context = Map.get(input, "context", 0)
    Logger.info("  [grep] '#{pattern}' in #{path}")

    glob_flag = if file_glob, do: " --include='#{file_glob}'", else: ""
    context_flag = if context > 0, do: " -C #{context}", else: ""

    cmd = "grep -rn#{context_flag}#{glob_flag} -- #{escape(pattern)} #{escape(path)} 2>/dev/null | head -500"

    case Golem.Sandbox.exec(cmd, timeout: 15_000) do
      {:ok, %{output: output, exit_code: 0}} ->
        {:continue, truncate(output, 50_000)}

      {:ok, %{output: "", exit_code: 1}} ->
        {:continue, "No matches found for '#{pattern}' in #{path}"}

      {:ok, %{output: output}} ->
        if output == "" do
          {:continue, "No matches found for '#{pattern}' in #{path}"}
        else
          {:continue, truncate(output, 50_000)}
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

  def execute(%{name: "update_progress", input: %{"items" => items}}, _depth) do
    parsed =
      Enum.map(items, fn item ->
        status =
          case Map.get(item, "status", "pending") do
            s when s in ["completed", "complete", "done"] -> :completed
            s when s in ["in_progress", "in-progress", "working", "active"] -> :in_progress
            _ -> :pending
          end

        %{text: Map.get(item, "text", ""), status: status}
      end)

    completed = Enum.count(parsed, &(&1.status == :completed))
    total = length(parsed)
    Logger.info("  [update_progress] #{completed}/#{total} completed")

    Golem.TUI.set_progress(parsed)
    # Store in persistent_term so runner state can pick it up for saving
    :persistent_term.put(:golem_progress, parsed)
    {:continue, "Progress updated (#{completed}/#{total} completed)."}
  end

  def execute(%{name: "parallel_sub_agents", input: %{"agents" => agents}}, depth) do
    count = length(agents)
    Logger.info("  [parallel_sub_agents] #{count} agents")

    # Spawn all sub-agents concurrently
    tasks =
      Enum.map(agents, fn agent ->
        goal = Map.fetch!(agent, "goal")
        context = Map.get(agent, "context", "")
        Task.async(fn -> Golem.Runner.run_sub_agent(goal, context, depth) end)
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
    Logger.info("  [sub_agent] depth=#{depth + 1} — #{String.slice(goal, 0, 200)}")

    case Golem.Runner.run_sub_agent(goal, context, depth) do
      {:ok, %{success: true, summary: summary}} ->
        {:continue, "Sub-agent completed successfully: #{summary}"}

      {:ok, %{success: false, summary: summary}} ->
        {:continue, "Sub-agent did not achieve its goal: #{summary}"}

      {:error, :max_steps_reached} ->
        {:continue, "Sub-agent hit its step limit without finishing. The sub-task may be partially complete — check the filesystem for progress."}

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

  defp escape(str), do: "'#{String.replace(str, "'", "'\\''")}'"

  defp truncate(text, max) when byte_size(text) > max do
    "[truncated to #{max} bytes]\n..." <>
      binary_part(text, byte_size(text) - max, max)
  end

  defp truncate(text, _max), do: text
end
