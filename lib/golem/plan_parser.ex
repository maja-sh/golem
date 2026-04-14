defmodule Golem.PlanParser do
  @moduledoc """
  Extracts verification commands from plan markdown.

  Plans can include `verify:` annotations on checklist items:

      - [ ] Create project directory
        verify: test -d /home/agent/project
      - [ ] Install dependencies
        verify: python3 -c "import flask"

  These are parsed into a map of normalized item text → shell command,
  used by the progress system to confirm items as they're marked done.
  """

  @doc """
  Extract verify commands from plan text.

  Returns a map of `%{normalized_text => shell_command}`.
  """
  @spec extract_verify_commands(String.t()) :: %{String.t() => String.t()}
  def extract_verify_commands(plan_text) when is_binary(plan_text) do
    plan_text
    |> String.split("\n")
    |> parse_lines(nil, %{})
  end

  def extract_verify_commands(_), do: %{}

  @doc """
  Find a verify command for the given item text.

  Tries normalized exact match first, then substring containment.
  Returns the shell command string or nil.
  """
  @spec find_verify_command(%{String.t() => String.t()}, String.t()) :: String.t() | nil
  def find_verify_command(verify_map, _item_text) when map_size(verify_map) == 0, do: nil

  def find_verify_command(verify_map, item_text) do
    normalized = normalize(item_text)

    # Exact match
    case Map.get(verify_map, normalized) do
      nil -> substring_match(verify_map, normalized)
      cmd -> cmd
    end
  end

  # --- Private ---

  defp parse_lines([], _current_item, acc), do: acc

  defp parse_lines([line | rest], current_item, acc) do
    cond do
      # Checklist item: - [ ] text or - [x] text
      match = Regex.run(~r/^[\s]*- \[[ x]\] (.+)$/i, line) ->
        [_, text] = match
        parse_lines(rest, normalize(text), acc)

      # Verify line (indented, follows a checklist item)
      current_item != nil && match_verify?(line) ->
        cmd = extract_verify_cmd(line)
        parse_lines(rest, nil, Map.put(acc, current_item, cmd))

      # Any other line clears the current item
      true ->
        parse_lines(rest, nil, acc)
    end
  end

  defp match_verify?(line) do
    Regex.match?(~r/^\s+verify:\s*\S/, line)
  end

  defp extract_verify_cmd(line) do
    line
    |> String.trim()
    |> String.replace_prefix("verify:", "")
    |> String.trim()
  end

  defp substring_match(verify_map, query) do
    Enum.find_value(verify_map, fn {key, cmd} ->
      if String.contains?(key, query) or String.contains?(query, key), do: cmd
    end)
  end

  defp normalize(text) do
    text
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end
end
