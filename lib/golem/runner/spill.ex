defmodule Golem.Runner.Spill do
  @moduledoc """
  Pure helpers for deciding when a tool result is too large to keep
  in context and, if so, building the preview + reference message
  that replaces it.

  Side effects (writing to the sandbox, emitting events, logging
  fallback failures) stay in `Golem.Runner`.
  """

  @threshold_bytes 12_000
  @preview_bytes 2_000
  @spillable_tools ~w(shell read_file grep glob list_directory web_search web_fetch)

  @doc """
  Bytes above which a result is spilled to disk.
  """
  def threshold_bytes, do: @threshold_bytes

  @doc """
  Max bytes kept inline as a preview when spilling.
  """
  def preview_bytes, do: @preview_bytes

  @doc """
  Tools whose output is eligible for spill. Things like `write_file`
  or `think` never produce large payloads and are skipped.
  """
  def spillable_tools, do: @spillable_tools

  @doc """
  Decide whether a tool's text result should be spilled to disk.

  Returns either `:passthrough` (keep the original content) or
  `{:spill, spill_path, preview_message}` (caller must write the file
  and emit the event, then use `preview_message` in place of `content`).

  Takes the tool_use descriptor as a map with `:name` and `:id` keys
  (matching `Golem.ToolHandler`'s `tc` struct).
  """
  def plan(content, %{name: name, id: id}) when is_binary(content) do
    if name in @spillable_tools and byte_size(content) > @threshold_bytes do
      path = "/tmp/golem-spill-#{id}.txt"
      preview = safe_prefix(content, @preview_bytes)
      message = build_message(path, preview, byte_size(content))
      {:spill, path, message}
    else
      :passthrough
    end
  end

  def plan(_content, _tc), do: :passthrough

  # Take at most `limit` bytes, trimming on a valid UTF-8 boundary so a
  # multi-byte character is never split.
  defp safe_prefix(content, limit) do
    if byte_size(content) <= limit do
      content
    else
      trim_to_utf8(content, limit)
    end
  end

  defp trim_to_utf8(_content, limit) when limit <= 0, do: ""

  defp trim_to_utf8(content, limit) do
    slice = binary_part(content, 0, limit)
    if String.valid?(slice), do: slice, else: trim_to_utf8(content, limit - 1)
  end

  defp build_message(path, preview, total_bytes) do
    size_kb = Float.round(total_bytes / 1024, 1)
    preview_kb = div(@preview_bytes, 1024)

    """
    <persisted-output path="#{path}">
    Output too large (#{size_kb} KB). Saved to #{path}.
    Use `read_file` with path="#{path}" (and optional offset/limit) if you need more than the preview.

    Preview (first #{preview_kb} KB):
    #{preview}
    </persisted-output>
    """
  end
end
