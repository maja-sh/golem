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

  defp truncate(text, max) when byte_size(text) > max do
    "[truncated to #{max} bytes]\n..." <>
      binary_part(text, byte_size(text) - max, max)
  end

  defp truncate(text, _max), do: text
end
