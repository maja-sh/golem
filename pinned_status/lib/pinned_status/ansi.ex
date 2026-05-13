defmodule PinnedStatus.ANSI do
  @moduledoc """
  ANSI helpers that need to be aware of escape codes — width counting,
  truncation, and word wrapping.

  Everything in here treats a string as a stream of visible characters
  interspersed with escape sequences (`\\e[...m`). Escapes contribute 0 to
  visible width but must be preserved verbatim in output.
  """

  @doc """
  Truncate a string so its visible (escape-stripped) length is at most
  `max_width`. ANSI escapes inside the kept prefix are preserved. A
  trailing `\\e[0m` is appended so any open color state is reset.
  """
  @spec truncate_visible(String.t(), non_neg_integer()) :: String.t()
  def truncate_visible(str, max_width) when is_binary(str) and max_width >= 0 do
    {result, _visible} =
      Regex.split(~r/(\e\[[0-9;]*m)/, str, include_captures: true)
      |> Enum.reduce({"", 0}, fn segment, {acc, visible} ->
        if String.starts_with?(segment, "\e[") do
          {acc <> segment, visible}
        else
          remaining = max_width - visible

          if remaining <= 0 do
            {acc, visible}
          else
            taken = String.slice(segment, 0, remaining)
            {acc <> taken, visible + String.length(taken)}
          end
        end
      end)

    result <> "\e[0m"
  end

  @doc """
  Visible (escape-stripped) length of a string.
  """
  @spec visible_length(String.t()) :: non_neg_integer()
  def visible_length(str) when is_binary(str) do
    Regex.replace(~r/\e\[[0-9;]*m/, str, "") |> String.length()
  end

  @doc """
  Wrap text to at most `width` visible characters per line, breaking at
  spaces. Embedded newlines split into separate logical lines first. If
  `width` is too small to be useful (< 10) the input is returned as one
  element.
  """
  @spec wrap_text(String.t(), pos_integer()) :: [String.t()]
  def wrap_text(text, width) when width > 10 do
    text
    |> String.split("\n")
    |> Enum.flat_map(&wrap_line(&1, width))
  end

  def wrap_text(text, _width), do: [text]

  defp wrap_line("", _width), do: [""]

  defp wrap_line(line, width) do
    words = String.split(line, " ")
    do_wrap(words, width, "", [])
  end

  defp do_wrap([], _width, current, acc), do: Enum.reverse([current | acc])

  defp do_wrap([word | rest], width, "", acc), do: do_wrap(rest, width, word, acc)

  defp do_wrap([word | rest], width, current, acc) do
    candidate = current <> " " <> word

    if String.length(candidate) > width do
      do_wrap([word | rest], width, "", [current | acc])
    else
      do_wrap(rest, width, candidate, acc)
    end
  end

  @doc """
  Number of columns reported by the terminal, or `default` if it can't
  be determined (e.g. when output is not a TTY).
  """
  @spec terminal_width(pos_integer()) :: pos_integer()
  def terminal_width(default \\ 80) do
    case :io.columns() do
      {:ok, cols} -> cols
      _ -> default
    end
  end
end
