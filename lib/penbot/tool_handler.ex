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
