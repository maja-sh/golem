defmodule Golem.FileCache do
  @moduledoc """
  In-memory cache of file contents from the container.
  Stores content + hash. On cache hit, verifies hash against
  the container to detect external edits.
  """

  use Agent
  require Logger

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Get cached content for a path. Verifies hash against container.
  Returns nil if not cached or if the file changed externally.
  """
  def get(path) do
    case Agent.get(__MODULE__, &Map.get(&1, path)) do
      nil -> nil
      {content, hash} ->
        case container_hash(path) do
          {:ok, ^hash} -> content
          _ ->
            Agent.update(__MODULE__, &Map.delete(&1, path))
            nil
        end
    end
  end

  @doc """
  Cache file content with its hash.
  """
  def put(path, content) do
    hash = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)
    Agent.update(__MODULE__, &Map.put(&1, path, {content, hash}))
  end

  @doc """
  Remove a file from the cache (e.g. after a sub-agent modified it).
  """
  def delete(path) do
    Agent.update(__MODULE__, &Map.delete(&1, path))
  end

  @doc """
  Find lines near a target string in cached content.
  Returns context to help the agent fix a failed edit.
  """
  def find_context(path, target, context_lines \\ 3) do
    case Agent.get(__MODULE__, &Map.get(&1, path)) do
      nil -> nil
      {content, _hash} -> do_find_context(content, target, context_lines)
    end
  end

  defp do_find_context(content, target, context_lines) do
    lines = String.split(content, "\n")
    target_first = target |> String.split("\n") |> List.first("") |> String.trim()
    target_lower = String.downcase(String.slice(target_first, 0, 100))

    best =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {line, idx} ->
        sim = String.jaro_distance(String.downcase(String.trim(line)), target_lower)
        {line, idx, sim}
      end)
      |> Enum.max_by(&elem(&1, 2), fn -> {nil, 0, 0} end)

    case best do
      {_, _, sim} when sim < 0.3 -> nil
      {_, line_num, _} ->
        start = max(1, line_num - context_lines)
        stop = min(length(lines), line_num + context_lines)

        lines
        |> Enum.with_index(1)
        |> Enum.filter(fn {_, idx} -> idx >= start and idx <= stop end)
        |> Enum.map(fn {line, idx} ->
          marker = if idx == line_num, do: "→ ", else: "  "
          "#{marker}#{idx}: #{line}"
        end)
        |> Enum.join("\n")
    end
  end

  defp container_hash(path) do
    case Golem.Sandbox.exec("md5sum #{escape(path)} 2>/dev/null | cut -d' ' -f1", timeout: 5_000) do
      {:ok, %{exit_code: 0, output: hash}} -> {:ok, String.trim(hash)}
      _ -> :error
    end
  end

  defp escape(path), do: "'#{String.replace(path, "'", "'\\''")}'"
end
