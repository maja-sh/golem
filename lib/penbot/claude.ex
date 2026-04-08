defmodule Penbot.Claude do
  @moduledoc """
  Claude API client. Supports tool use with extended thinking.
  """

  require Logger

  @base_url "https://api.anthropic.com/v1"

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

    start = System.monotonic_time(:millisecond)

    case Req.post("#{@base_url}/messages",
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           retry: :transient,
           max_retries: 3,
           receive_timeout: 120_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        elapsed = System.monotonic_time(:millisecond) - start
        usage = Map.get(body, "usage", %{})
        input_tokens = Map.get(usage, "input_tokens", 0)
        output_tokens = Map.get(usage, "output_tokens", 0)

        Logger.info(
          "Claude #{model} — #{elapsed}ms — #{input_tokens} in / #{output_tokens} out"
        )

        {:ok, parse_response(body)}

      {:ok, %{status: status, body: body}} ->
        elapsed = System.monotonic_time(:millisecond) - start
        Logger.error("Claude error #{status} after #{elapsed}ms: #{inspect(body)}")
        {:error, {status, body}}

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - start
        Logger.error("Claude request failed after #{elapsed}ms: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_response(body) do
    content = Map.get(body, "content", [])
    stop_reason = Map.get(body, "stop_reason", "end_turn")

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
      stop_reason: stop_reason
    }
  end

  defp api_key! do
    System.get_env("ANTHROPIC_API_KEY") ||
      raise "ANTHROPIC_API_KEY environment variable not set"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_thinking(body, nil), do: body

  defp maybe_put_thinking(body, budget) do
    body
    |> Map.put(:thinking, %{type: "enabled", budget_tokens: budget})
  end
end
