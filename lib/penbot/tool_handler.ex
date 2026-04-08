defmodule Penbot.ToolHandler do
  @moduledoc """
  Dispatches tool calls to their implementations and formats results.
  """

  require Logger

  @doc """
  Execute a tool call. Returns {:continue, result_text} or {:done, summary}.
  """
  def execute(%{name: "shell", input: %{"command" => command}}) do
    Logger.info("  [shell] #{String.slice(command, 0, 200)}")

    case Penbot.Sandbox.exec(command) do
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

  def execute(%{name: "write_file", input: %{"path" => path, "content" => content}}) do
    Logger.info("  [write_file] #{path} (#{byte_size(content)} bytes)")

    case Penbot.Sandbox.write_file(path, content) do
      :ok -> {:continue, "File written to #{path}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "read_file", input: %{"path" => path}}) do
    Logger.info("  [read_file] #{path}")

    case Penbot.Sandbox.read_file(path) do
      {:ok, content} -> {:continue, truncate(content, 50_000)}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "edit_file", input: %{"path" => path, "old_string" => old, "new_string" => new}}) do
    Logger.info("  [edit_file] #{path}")

    case Penbot.Sandbox.read_file(path) do
      {:ok, content} ->
        case String.split(content, old, parts: 2) do
          [_before, _after] ->
            updated = String.replace(content, old, new, global: false)

            case Penbot.Sandbox.write_file(path, updated) do
              :ok -> {:continue, "Edit applied to #{path}"}
              {:error, reason} -> {:continue, "[error] Failed to write: #{inspect(reason)}"}
            end

          [_no_match] ->
            {:continue, "[error] old_string not found in #{path}. Make sure it matches exactly, including whitespace and indentation."}
        end

      {:error, reason} ->
        {:continue, "[error] Failed to read #{path}: #{inspect(reason)}"}
    end
  end

  def execute(%{name: "list_directory", input: %{"path" => path}}) do
    Logger.info("  [list_directory] #{path}")

    case Penbot.Sandbox.exec("ls -lAh #{escape(path)}", timeout: 10_000) do
      {:ok, %{output: output, exit_code: 0}} -> {:continue, truncate(output, 50_000)}
      {:ok, %{output: output}} -> {:continue, "[error] #{output}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "glob", input: input}) do
    pattern = Map.fetch!(input, "pattern")
    path = Map.get(input, "path", ".")
    Logger.info("  [glob] #{pattern} in #{path}")

    # Use find with -path for glob matching, or shell globstar
    cmd = "cd #{escape(path)} && find . -path './#{pattern}' -type f 2>/dev/null | head -200 | sort"

    case Penbot.Sandbox.exec(cmd, timeout: 15_000) do
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

  def execute(%{name: "grep", input: input}) do
    pattern = Map.fetch!(input, "pattern")
    path = Map.get(input, "path", ".")
    file_glob = Map.get(input, "glob")
    context = Map.get(input, "context", 0)
    Logger.info("  [grep] '#{pattern}' in #{path}")

    glob_flag = if file_glob, do: " --include='#{file_glob}'", else: ""
    context_flag = if context > 0, do: " -C #{context}", else: ""

    cmd = "grep -rn#{context_flag}#{glob_flag} -- #{escape(pattern)} #{escape(path)} 2>/dev/null | head -500"

    case Penbot.Sandbox.exec(cmd, timeout: 15_000) do
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

  def execute(%{name: "web_search", input: %{"query" => query}}) do
    Logger.info("  [web_search] #{query}")

    case Penbot.Web.search(query) do
      {:ok, result} -> {:continue, truncate(result, 50_000)}
      {:error, reason} -> {:continue, "[error] Web search failed: #{inspect(reason)}"}
    end
  end

  def execute(%{name: "web_fetch", input: %{"url" => url}}) do
    Logger.info("  [web_fetch] #{url}")

    case Penbot.Web.fetch(url) do
      {:ok, content} -> {:continue, truncate(content, 50_000)}
      {:error, reason} -> {:continue, "[error] Web fetch failed: #{inspect(reason)}"}
    end
  end

  def execute(%{name: "think", input: %{"reasoning" => reasoning}}) do
    Logger.info("  [think] #{String.slice(reasoning, 0, 200)}")
    # The reasoning is captured in the conversation history.
    # Signal the runner to consider re-planning.
    {:think, reasoning}
  end

  def execute(%{name: "screenshot", input: _input}) do
    Logger.info("  [screenshot]")

    case Penbot.Screenshot.capture() do
      {:ok, %{path: path, base64: base64}} ->
        {:continue_with_image, %{text: "Screenshot saved to #{path}", base64: base64}}

      {:error, reason} ->
        {:continue, "[error] Screenshot failed: #{inspect(reason)}"}
    end
  end

  def execute(%{name: "gui_click", input: %{"x" => x, "y" => y}}) do
    Logger.info("  [gui_click] #{x},#{y}")

    case Penbot.Sandbox.exec("DISPLAY=:99 xdotool mousemove #{x} #{y} click 1", timeout: 5_000) do
      {:ok, %{exit_code: 0}} -> {:continue, "Clicked at (#{x}, #{y})"}
      {:ok, %{output: out}} -> {:continue, "[error] #{out}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "gui_type", input: %{"text" => text}}) do
    Logger.info("  [gui_type] #{String.slice(text, 0, 50)}")
    # Use xdotool type with --clearmodifiers to avoid modifier key issues
    escaped = String.replace(text, "'", "'\\''")

    case Penbot.Sandbox.exec("DISPLAY=:99 xdotool type --clearmodifiers '#{escaped}'", timeout: 10_000) do
      {:ok, %{exit_code: 0}} -> {:continue, "Typed text"}
      {:ok, %{output: out}} -> {:continue, "[error] #{out}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "gui_key", input: %{"key" => key}}) do
    Logger.info("  [gui_key] #{key}")

    case Penbot.Sandbox.exec("DISPLAY=:99 xdotool key --clearmodifiers #{key}", timeout: 5_000) do
      {:ok, %{exit_code: 0}} -> {:continue, "Pressed #{key}"}
      {:ok, %{output: out}} -> {:continue, "[error] #{out}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "gui_scroll", input: input}) do
    direction = Map.get(input, "direction", "down")
    clicks = Map.get(input, "clicks", 3)
    button = if direction == "up", do: 4, else: 5
    Logger.info("  [gui_scroll] #{direction} #{clicks}")

    cmds = Enum.map_join(1..clicks, " && ", fn _ -> "DISPLAY=:99 xdotool click #{button}" end)

    case Penbot.Sandbox.exec(cmds, timeout: 5_000) do
      {:ok, %{exit_code: 0}} -> {:continue, "Scrolled #{direction} #{clicks} clicks"}
      {:ok, %{output: out}} -> {:continue, "[error] #{out}"}
      {:error, reason} -> {:continue, "[error] #{inspect(reason)}"}
    end
  end

  def execute(%{name: "done", input: input}) do
    success = Map.get(input, "success", false)
    summary = Map.get(input, "summary", "No summary provided")
    Logger.info("  [done] success=#{success} — #{summary}")
    {:done, %{success: success, summary: summary}}
  end

  def execute(%{name: name}) do
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
