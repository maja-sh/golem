defmodule Golem.Runner.Compaction do
  @moduledoc """
  Pure helpers used by the runner to shrink conversation context.

  * **Token estimation** — a cheap codepoint-based estimate used to
    decide when to trigger snip/full compaction.
  * **truncate_str** — small string helper used by the runner and
    reminder. Lives here because it predates the reminder module.

  Microcompaction (replacing old tool_results with `[cleared: …]`
  signatures) used to live here too. It was removed because it caused
  the agent to re-read the same files repeatedly — the cleared marker
  preserved the *fact* a file had been read but not its content, and
  the model would re-run the read tool to recover it. The cost of the
  re-reads exceeded the tokens microcompaction saved.
  """

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
