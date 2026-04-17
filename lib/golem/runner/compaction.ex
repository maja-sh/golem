defmodule Golem.Runner.Compaction do
  @moduledoc """
  Pure helpers used by the runner to shrink conversation context.

  Two concerns live here:

  * **Microcompaction signatures** — build a compact `[cleared: …]`
    string for an old tool_result so the agent retains "what did I
    already try?" even after the raw output is dropped.
  * **Token estimation** — a cheap codepoint-based estimate used to
    decide when to trigger snip/full compaction.

  All functions are pure. Side effects (reading `:persistent_term`
  floors, writing `:golem_last_input_tokens`, splitting messages)
  stay in `Golem.Runner`.
  """

  @doc """
  Build a compact signature describing a tool call whose result was
  cleared. Examples:

      [cleared: shell "npm run build" → exit 137, 2.3KB]
      [cleared: read_file /home/agent/app/src/main.js, 45.0KB]
      [cleared: grep "has_injury" → ok, 12.0KB]
  """
  def build_cleared_signature(%{name: name, input: input}, content)
      when is_binary(content) do
    input_str = summarize_tool_input(name, input)
    size_str = format_size(byte_size(content))
    status = extract_status_hint(name, content)

    parts =
      ["[cleared: #{name}"] ++
        if(input_str != "", do: [" ", input_str], else: []) ++
        if(status != "", do: [" → ", status], else: []) ++
        [", ", size_str, "]"]

    IO.iodata_to_binary(parts)
  end

  @doc """
  Short one-line summary of a tool's input for display in a cleared
  signature or recent-commands list.
  """
  def summarize_tool_input("shell", %{"command" => cmd}), do: ~s("#{truncate_str(cmd, 80)}")
  def summarize_tool_input("read_file", %{"path" => path}), do: path
  def summarize_tool_input("grep", %{"pattern" => p}), do: ~s("#{truncate_str(p, 60)}")
  def summarize_tool_input("glob", %{"pattern" => p}), do: p
  def summarize_tool_input("list_directory", %{"path" => path}), do: path
  def summarize_tool_input("web_search", %{"query" => q}), do: ~s("#{truncate_str(q, 60)}")
  def summarize_tool_input("web_fetch", %{"url" => u}), do: u
  def summarize_tool_input("browse", %{"url" => u}), do: u
  def summarize_tool_input(_, _), do: ""

  @doc """
  Classify a tool's result into a short status hint (e.g. `"exit 137"`,
  `"timed out"`, `"stalled"`, `"ok"`). Empty string when no hint applies.
  """
  def extract_status_hint("shell", content) when is_binary(content) do
    cond do
      String.starts_with?(content, "[exit code ") ->
        case Regex.run(~r/^\[exit code (\d+)\]/, content) do
          [_, code] -> "exit #{code}"
          _ -> "failed"
        end

      String.starts_with?(content, "[command timed out]") ->
        "timed out"

      String.starts_with?(content, "[command stalled") ->
        "stalled"

      String.starts_with?(content, "[error]") ->
        "error"

      true ->
        "ok"
    end
  end

  def extract_status_hint(_, "[error]" <> _), do: "error"
  def extract_status_hint(_, _), do: ""

  @doc """
  Format a byte count as "NB", "N.NKB", or "N.NMB".
  """
  def format_size(bytes) when bytes < 1024, do: "#{bytes}B"
  def format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)}KB"
  def format_size(bytes), do: "#{Float.round(bytes / 1024 / 1024, 1)}MB"

  @doc """
  Truncate a string to `max` codepoints, appending "..." when cut.
  Returns `to_string(s)` unchanged for non-binary inputs.
  """
  def truncate_str(s, max) when is_binary(s) do
    if String.length(s) > max, do: String.slice(s, 0, max - 3) <> "...", else: s
  end

  def truncate_str(s, _max), do: to_string(s)

  # --- Token estimation ---

  @doc """
  Estimate tokens in a single text block. Uses codepoint count (not
  byte count) so UTF-8 with multi-byte characters produces a
  comparable estimate to ASCII. ~3 codepoints per token is a
  reasonable middle ground for Claude's tokenizer.
  """
  def estimate_text_tokens(text) when is_binary(text), do: div(String.length(text), 3)
  def estimate_text_tokens(_), do: 0

  @doc """
  Estimate tokens in a list of messages. Images contribute a flat
  2000-token allowance; other unknown blocks add 50 overhead.
  """
  def estimate_messages_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc -> acc + estimate_message_tokens(msg) end)
  end

  def estimate_message_tokens(%{content: content}) when is_binary(content) do
    estimate_text_tokens(content)
  end

  def estimate_message_tokens(%{"content" => content}) when is_binary(content) do
    estimate_text_tokens(content)
  end

  def estimate_message_tokens(%{"content" => blocks}) when is_list(blocks) do
    estimate_message_tokens(%{content: blocks})
  end

  def estimate_message_tokens(%{content: blocks}) when is_list(blocks) do
    Enum.reduce(blocks, 0, fn
      %{type: "text", text: text}, acc -> acc + estimate_text_tokens(text)
      %{"type" => "text", "text" => text}, acc -> acc + estimate_text_tokens(text)
      %{type: "tool_result", content: content}, acc when is_binary(content) -> acc + estimate_text_tokens(content)
      %{"type" => "tool_result", "content" => content}, acc when is_binary(content) -> acc + estimate_text_tokens(content)
      %{type: "tool_use", input: input}, acc -> acc + estimate_text_tokens(inspect(input))
      %{"type" => "tool_use", "input" => input}, acc -> acc + estimate_text_tokens(inspect(input))
      %{type: "image"}, acc -> acc + 2000
      _, acc -> acc + 50
    end)
  end

  def estimate_message_tokens(_), do: 50
end
