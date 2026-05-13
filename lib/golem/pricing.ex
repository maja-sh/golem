defmodule Golem.Pricing do
  @moduledoc """
  Per-million-token pricing lookup. Returns a `%{input, output,
  cache_read, cache_create}` map for any model the runner might call.

  ## Lookup chain (highest precedence first)

    1. **Explicit override** — `pricing:` block in `.golem/config.yaml`,
       keyed by exact model name. Each field is optional and merges
       over the underlying default.
    2. **Built-in Anthropic defaults** — keyed by model substring
       (`opus`, `sonnet`, `haiku`).
    3. **OpenRouter** — fetched once from `GET /api/v1/models` and
       cached for an hour. Model names containing a `/` are treated as
       OpenRouter routes.
    4. **Unknown** — zero pricing returned and a one-time warning
       logged. Better than misreporting against a default that doesn't
       fit the model's actual cost.

  Cache and cost tokens (`cache_read`, `cache_create`) are Anthropic
  concepts; for other providers they're always 0.
  """

  require Logger

  @anthropic_opus %{input: 15.0, output: 75.0, cache_read: 1.5, cache_create: 18.75}
  @anthropic_sonnet %{input: 3.0, output: 15.0, cache_read: 0.3, cache_create: 3.75}
  @anthropic_haiku %{input: 1.0, output: 5.0, cache_read: 0.1, cache_create: 1.25}
  @zero %{input: 0.0, output: 0.0, cache_read: 0.0, cache_create: 0.0}

  @openrouter_cache_key :golem_openrouter_pricing
  @openrouter_cache_ttl_s 3600

  @doc """
  Pricing for `model` as a map of dollars per million tokens.
  """
  @spec for(String.t()) :: %{
          input: float(),
          output: float(),
          cache_read: float(),
          cache_create: float()
        }
  def for(model) when is_binary(model) do
    base = base_pricing(model)
    overrides = config_override(model)
    merge(base, overrides)
  end

  defp config_override(model) do
    case Golem.Config.raw_yaml() |> get_in(["pricing", model]) do
      nil -> %{}
      m when is_map(m) -> m
    end
  end

  defp merge(base, overrides) do
    Enum.reduce(base, %{}, fn {key, default}, acc ->
      override = overrides[to_string(key)] || overrides[key]
      Map.put(acc, key, if(is_number(override), do: override * 1.0, else: default))
    end)
  end

  # --- Provider detection + per-provider lookup ---

  defp base_pricing(model) do
    cond do
      anthropic?(model) -> anthropic_pricing(model)
      openrouter?(model) -> openrouter_pricing(model)
      true -> warn_unknown(model)
    end
  end

  defp anthropic?(model), do: String.starts_with?(model, "claude-")

  # OpenRouter models are `vendor/model` paths (qwen/qwen-...,
  # mistralai/mistral-..., etc). The `/` is the distinguishing marker.
  defp openrouter?(model), do: String.contains?(model, "/")

  defp anthropic_pricing(model) do
    cond do
      String.contains?(model, "opus") -> @anthropic_opus
      String.contains?(model, "haiku") -> @anthropic_haiku
      true -> @anthropic_sonnet
    end
  end

  defp openrouter_pricing(model) do
    case load_openrouter_catalogue() do
      {:ok, catalogue} ->
        case Map.get(catalogue, model) do
          nil ->
            warn_unknown(model)

          %{input: _} = price ->
            price
        end

      :error ->
        # Fetch failed — return zero rather than guess.
        @zero
    end
  end

  # --- OpenRouter catalogue fetch + cache ---

  defp load_openrouter_catalogue do
    case :persistent_term.get(@openrouter_cache_key, :not_loaded) do
      {fetched_at, catalogue} when is_integer(fetched_at) ->
        age = System.system_time(:second) - fetched_at

        if age < @openrouter_cache_ttl_s do
          {:ok, catalogue}
        else
          fetch_and_cache()
        end

      :not_loaded ->
        fetch_and_cache()
    end
  end

  defp fetch_and_cache do
    case fetch_openrouter_models() do
      {:ok, catalogue} ->
        :persistent_term.put(@openrouter_cache_key, {System.system_time(:second), catalogue})
        {:ok, catalogue}

      {:error, reason} ->
        Logger.warning("Failed to fetch OpenRouter pricing: #{inspect(reason)}")
        :error
    end
  end

  defp fetch_openrouter_models do
    url = openrouter_base_url() <> "/models"

    case Req.get(url, receive_timeout: 10_000, retry: false) do
      {:ok, %{status: 200, body: %{"data" => entries}}} when is_list(entries) ->
        {:ok, build_catalogue(entries)}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp openrouter_base_url do
    Application.get_env(:golem, :openrouter_base_url, "https://openrouter.ai/api/v1")
  end

  # OpenRouter prices are dollars per *single* token, as strings like
  # "0.00000018". Convert to dollars-per-million to match the
  # Anthropic-shaped pricing maps the rest of Golem uses.
  defp build_catalogue(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      with id when is_binary(id) <- entry["id"],
           %{"prompt" => prompt, "completion" => completion} <- entry["pricing"] do
        Map.put(acc, id, %{
          input: to_per_million(prompt),
          output: to_per_million(completion),
          cache_read: 0.0,
          cache_create: 0.0
        })
      else
        _ -> acc
      end
    end)
  end

  defp to_per_million(value) when is_binary(value) do
    case Float.parse(value) do
      {n, _} -> n * 1_000_000
      :error -> 0.0
    end
  end

  defp to_per_million(value) when is_number(value), do: value * 1_000_000
  defp to_per_million(_), do: 0.0

  # --- Unknown model handling ---

  # Warn once per model so the operator notices missing pricing without
  # flooding the log. Falls back to zero so cost reports are obviously
  # wrong (`$0`) rather than silently wrong (drifting Sonnet defaults).
  defp warn_unknown(model) do
    seen = :persistent_term.get(:golem_unknown_pricing_seen, MapSet.new())

    unless MapSet.member?(seen, model) do
      Logger.warning(
        "No pricing for model #{inspect(model)}. Cost reports will show $0. " <>
          "Add a `pricing:` entry in .golem/config.yaml to fix."
      )

      :persistent_term.put(:golem_unknown_pricing_seen, MapSet.put(seen, model))
    end

    @zero
  end
end
