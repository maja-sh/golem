defmodule Penbot.Claude do
  @moduledoc """
  Claude API client. Supports tool use with extended thinking.
  """

  require Logger

  @base_url "https://api.anthropic.com/v1"
  @max_retries 5
  @initial_backoff_ms 1_000
  @retryable_statuses [429, 500, 502, 503, 529]

  @doc """
  Call Claude with tool use. Returns {:ok, response} or {:error, reason}.

  Response is a map with:
  - :thinking - extended thinking text (if enabled)
  - :text - any text content
  - :tool_use - list of %{id, name, input} tool calls
  - :stop_reason - "end_turn", "tool_use", etc.
  """
  def call(messages, opts \\ []) do
    api_key = api_key!()
    model = opts[:model] || Application.get_env(:penbot, :executor_model)
    max_tokens = opts[:max_tokens] || Application.get_env(:penbot, :executor_max_tokens)
    system = opts[:system]
    tools = opts[:tools]
    thinking_budget = opts[:thinking_budget]

    body =
      %{model: model, max_tokens: max_tokens, messages: messages}
      |> maybe_put(:system, system)
      |> maybe_put(:tools, tools)
      |> maybe_put_thinking(thinking_budget)

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    do_call(body, headers, model, 0)
  end

  defp do_call(body, headers, model, attempt) do
    start = System.monotonic_time(:millisecond)

    # Disable Req's built-in retry — we handle it ourselves
    case Req.post("#{@base_url}/messages",
           json: body,
           headers: headers,
           retry: false,
           receive_timeout: 180_000
         ) do
      {:ok, %{status: 200, body: resp}} ->
        elapsed = System.monotonic_time(:millisecond) - start
        usage = Map.get(resp, "usage", %{})
        input_tokens = Map.get(usage, "input_tokens", 0)
        output_tokens = Map.get(usage, "output_tokens", 0)
        cache_read = Map.get(usage, "cache_read_input_tokens", 0)
        cache_create = Map.get(usage, "cache_creation_input_tokens", 0)

        cache_info =
          if cache_read > 0 or cache_create > 0,
            do: " (cache: #{cache_read} read, #{cache_create} create)",
            else: ""

        Logger.info(
          "Claude #{model} — #{elapsed}ms — #{input_tokens} in / #{output_tokens} out#{cache_info}"
        )

        {:ok, parse_response(resp)}

      {:ok, %{status: status, body: resp}} when status in @retryable_statuses ->
        elapsed = System.monotonic_time(:millisecond) - start

        if attempt < @max_retries do
          backoff = backoff_ms(attempt)
          Logger.warning("Claude #{status} after #{elapsed}ms — retry #{attempt + 1}/#{@max_retries} in #{backoff}ms")
          Process.sleep(backoff)
          do_call(body, headers, model, attempt + 1)
        else
          Logger.error("Claude #{status} after #{elapsed}ms — exhausted #{@max_retries} retries")
          {:error, {status, resp}}
        end

      {:ok, %{status: status, body: resp}} ->
        elapsed = System.monotonic_time(:millisecond) - start
        Logger.error("Claude error #{status} after #{elapsed}ms: #{inspect(resp)}")
        {:error, {status, resp}}

      {:error, %Req.TransportError{} = reason} when attempt < @max_retries ->
        backoff = backoff_ms(attempt)
        Logger.warning("Claude transport error — retry #{attempt + 1}/#{@max_retries} in #{backoff}ms: #{inspect(reason)}")
        Process.sleep(backoff)
        do_call(body, headers, model, attempt + 1)

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - start
        Logger.error("Claude request failed after #{elapsed}ms: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp backoff_ms(attempt) do
    # Exponential backoff with jitter: 1s, 2s, 4s, 8s, 16s + random 0-1s
    base = @initial_backoff_ms * :math.pow(2, attempt) |> round()
    jitter = :rand.uniform(1_000)
    base + jitter
  end

  defp parse_response(body) do
    content = Map.get(body, "content", [])
    stop_reason = Map.get(body, "stop_reason", "end_turn")
    usage = Map.get(body, "usage", %{})

    thinking =
      content
      |> Enum.filter(&(&1["type"] == "thinking"))
      |> Enum.map_join("\n", & &1["thinking"])
      |> case do
        "" -> nil
        t -> t
      end

    text =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])
      |> case do
        "" -> nil
        t -> t
      end

    tool_use =
      content
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn block ->
        %{
          id: block["id"],
          name: block["name"],
          input: block["input"]
        }
      end)

    %{
      thinking: thinking,
      text: text,
      tool_use: tool_use,
      stop_reason: stop_reason,
      usage: %{
        input_tokens: Map.get(usage, "input_tokens", 0),
        output_tokens: Map.get(usage, "output_tokens", 0),
        cache_read: Map.get(usage, "cache_read_input_tokens", 0),
        cache_create: Map.get(usage, "cache_creation_input_tokens", 0)
      }
    }
  end

  defp api_key! do
    System.get_env("ANTHROPIC_API_KEY") ||
      raise "ANTHROPIC_API_KEY environment variable not set"
  end

  defp maybe_put(map, _key, nil), do: map

  # System prompt: wrap as cacheable content block
  defp maybe_put(map, :system, text) when is_binary(text) do
    Map.put(map, :system, [
      %{type: "text", text: text, cache_control: %{type: "ephemeral"}}
    ])
  end

  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_thinking(body, nil), do: body

  defp maybe_put_thinking(body, budget) do
    body
    |> Map.put(:thinking, %{type: "enabled", budget_tokens: budget})
  end
end
