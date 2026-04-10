defmodule Golem.State do
  @moduledoc """
  Persists and loads run state for resume support.
  State is saved to runs/<run_id>/state.json.
  """

  require Logger

  @runs_dir "runs"

  @doc """
  Generate a new run ID.
  """
  def new_run_id do
    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%d_%H%M%S")

    short = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "#{timestamp}_#{short}"
  end

  @doc """
  Always save — it's just a JSON write and ensures we always have
  a recent checkpoint for resume.
  """
  def should_save?(_step), do: true

  @doc """
  Save run state to disk.
  """
  def save(run_id, state) do
    dir = run_dir(run_id)
    File.mkdir_p!(dir)
    path = Path.join(dir, "state.json")

    data = %{
      run_id: run_id,
      goal: state.goal,
      plan: state.plan,
      step: state.step,
      max_steps: state.max_steps,
      depth: state.depth,
      history: encode_history(state.history),
      messages: state.messages,
      costs: Map.get(state, :costs, %{input: 0, output: 0, cache_read: 0, cache_create: 0}),
      errors: Map.get(state, :errors, []),
      agents_md: Map.get(state, :agents_md),
      progress: Map.get(state, :progress, []) |> Enum.map(fn item -> %{text: item.text, status: Atom.to_string(item.status)} end),
      phase_costs: Map.get(state, :phase_costs, []) |> Enum.map(fn {n, c} -> %{name: n, cost: c} end),
      last_completed: Map.get(state, :last_completed, 0),
      saved_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    json = Jason.encode!(data, pretty: true)
    File.write!(path, json)
    Logger.debug("State saved to #{path} (step #{state.step})")
    :ok
  end

  @doc """
  Load run state from disk. Returns {:ok, state_map} or {:error, reason}.
  """
  def load(run_id) do
    path = Path.join(run_dir(run_id), "state.json")

    case File.read(path) do
      {:ok, json} ->
        data = Jason.decode!(json)

        state = %{
          goal: data["goal"],
          plan: data["plan"],
          step: data["step"],
          max_steps: data["max_steps"],
          depth: data["depth"],
          history: decode_history(data["history"]),
          messages: atomize_messages(data["messages"]),
          costs: decode_costs(data["costs"]),
          errors: data["errors"] || [],
          agents_md: data["agents_md"],
          progress: decode_progress(data["progress"]),
          phase_costs: decode_phase_costs(data["phase_costs"]),
          last_completed: data["last_completed"] || 0
        }

        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List all saved runs.
  """
  def list_runs do
    case File.ls(@runs_dir) do
      {:ok, dirs} ->
        dirs
        |> Enum.sort(:desc)
        |> Enum.map(fn dir ->
          path = Path.join([@runs_dir, dir, "state.json"])

          case File.read(path) do
            {:ok, json} ->
              data = Jason.decode!(json)
              %{
                id: dir,
                goal: String.slice(data["goal"] || "", 0, 80),
                step: data["step"],
                max_steps: data["max_steps"],
                saved_at: data["saved_at"]
              }

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp run_dir(run_id), do: Path.join(@runs_dir, run_id)

  defp encode_history(history) do
    Enum.map(history, fn {tool, input, result} ->
      %{"tool" => tool, "input" => input, "result" => result}
    end)
  end

  defp decode_history(history) do
    Enum.map(history || [], fn entry ->
      {entry["tool"], entry["input"], entry["result"]}
    end)
  end

  defp decode_costs(nil), do: %{input: 0, output: 0, cache_read: 0, cache_create: 0}
  defp decode_costs(costs) do
    %{
      input: Map.get(costs, "input", 0),
      output: Map.get(costs, "output", 0),
      cache_read: Map.get(costs, "cache_read", 0),
      cache_create: Map.get(costs, "cache_create", 0)
    }
  end

  defp decode_progress(nil), do: []
  defp decode_progress(items) do
    Enum.map(items, fn item ->
      %{
        text: Map.get(item, "text", ""),
        status: String.to_atom(Map.get(item, "status", "pending"))
      }
    end)
  end

  defp decode_phase_costs(nil), do: []
  defp decode_phase_costs(costs) do
    Enum.map(costs, fn
      [name, cost] -> {name, cost}
      %{"name" => name, "cost" => cost} -> {name, cost}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Ensure message keys are atoms (role, content) when loaded from JSON
  defp atomize_messages(messages) do
    Enum.map(messages || [], fn msg ->
      msg
      |> Enum.map(fn
        {"role", v} -> {:role, v}
        {"content", v} -> {:content, atomize_content(v)}
        {k, v} -> {String.to_existing_atom(k), v}
      end)
      |> Map.new()
    end)
  end

  # Content can be a string or a list of content blocks
  defp atomize_content(content) when is_binary(content), do: content
  defp atomize_content(content) when is_list(content) do
    Enum.map(content, fn
      block when is_map(block) ->
        block
        |> Enum.map(fn
          {"type", v} -> {:type, v}
          {k, v} when is_binary(k) ->
            try do
              {String.to_existing_atom(k), v}
            rescue
              ArgumentError -> {k, v}
            end
          other -> other
        end)
        |> Map.new()

      other -> other
    end)
  end
  defp atomize_content(other), do: other
end
