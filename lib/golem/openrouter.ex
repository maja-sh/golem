defmodule Golem.OpenRouter do
  @moduledoc """
  OpenRouter API client. Speaks the OpenAI-compatible `/chat/completions`
  endpoint, translating Golem's Anthropic-flavored message and tool
  shape on the way in and the OpenAI response shape on the way out so
  the rest of the system stays uniform.

  Capabilities deliberately *not* supported (silently ignored if asked):

    * extended thinking (`thinking_budget`) — Anthropic-specific
    * prompt caching breakpoints — Anthropic-specific
    * `cache_create` / `cache_read` usage fields — always reported as 0

  Picks up its API key from the env var named by the
  `openrouter_api_key_env` Application setting (default
  `OPENROUTER_API_KEY`).
  """

  @behaviour Golem.Provider

  require Logger

  @base_url "https://openrouter.ai/api/v1"
  @max_retries 10
  @initial_backoff_ms 2_000
  @max_backoff_ms 120_000
  @retryable_statuses [429, 500, 502, 503]

  @impl Golem.Provider
  def call(messages, opts \\ []) do
    api_key = api_key!()
    model = opts[:model] || raise ArgumentError, "Golem.OpenRouter.call/2 requires :model"
    max_tokens = opts[:max_tokens] || 4_000
    system = opts[:system]
    tools = opts[:tools]

    body =
      %{
        model: model,
        max_tokens: max_tokens,
        messages: to_openai_messages(messages, system)
      }
      |> maybe_put(:tools, openai_tools(tools))

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      # Recommended by OpenRouter for app identification — used to
      # populate their dashboard "calling app" field. Optional.
      {"http-referer", "https://github.com/hbackman/golem"},
      {"x-title", "Golem"}
    ]

    result = do_call(body, headers, 0)
    Golem.Output.current().api_retry_cleared()
    result
  end

  # --- Retry loop ---

  defp do_call(body, headers, attempt) do
    case Req.post(base_url() <> "/chat/completions",
           json: body,
           headers: headers,
           receive_timeout: 600_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok, from_openai_response(resp)}

      {:ok, %{status: status, body: body}} when status in @retryable_statuses ->
        retry_or_give_up(body, headers, attempt, "HTTP #{status}")

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        retry_or_give_up(body, headers, attempt, "transport: #{inspect(reason)}")
    end
  end

  defp retry_or_give_up(body, headers, attempt, reason) do
    if attempt + 1 >= @max_retries do
      {:error, reason}
    else
      backoff = min(@initial_backoff_ms * :math.pow(2, attempt), @max_backoff_ms) |> round()
      Golem.Output.current().api_retry(attempt + 1, @max_retries, backoff, reason)
      Process.sleep(backoff)
      do_call(body, headers, attempt + 1)
    end
  end

  # --- Anthropic → OpenAI translation ---

  # OpenAI uses a flat array where:
  #   - system: top-level field OR a {role: "system"} message
  #   - tool calls: assistant message with `tool_calls: [...]`
  #   - tool results: separate {role: "tool", tool_call_id, content} message
  # Anthropic uses content blocks within user/assistant messages.
  defp to_openai_messages(messages, system) do
    system_msg = if system, do: [%{role: "system", content: system}], else: []

    body =
      Enum.flat_map(messages, fn msg ->
        role = role_of(msg)
        content = content_of(msg)
        translate_message(role, content)
      end)

    system_msg ++ body
  end

  defp role_of(%{role: r}), do: r
  defp role_of(%{"role" => r}), do: r

  defp content_of(%{content: c}), do: c
  defp content_of(%{"content" => c}), do: c

  # Plain string content stays as-is.
  defp translate_message(role, content) when is_binary(content) do
    [%{role: role, content: content}]
  end

  # Block content — extract text, tool_use, tool_result separately.
  defp translate_message(role, blocks) when is_list(blocks) do
    {text_parts, tool_uses, tool_results} = partition_blocks(blocks)

    base =
      cond do
        role == "assistant" and (text_parts != [] or tool_uses != []) ->
          msg = %{role: "assistant", content: Enum.join(text_parts, "")}
          if tool_uses != [], do: [Map.put(msg, :tool_calls, tool_uses)], else: [msg]

        role == "user" and text_parts != [] ->
          [%{role: "user", content: Enum.join(text_parts, "")}]

        true ->
          []
      end

    # Each tool_result becomes its own {role: "tool", ...} message.
    base ++ Enum.map(tool_results, fn tr ->
      %{role: "tool", tool_call_id: tr.id, content: tr.content}
    end)
  end

  defp translate_message(_role, _), do: []

  defp partition_blocks(blocks) do
    Enum.reduce(blocks, {[], [], []}, fn block, {texts, uses, results} ->
      case classify_block(block) do
        {:text, t} -> {texts ++ [t], uses, results}
        {:tool_use, u} -> {texts, uses ++ [u], results}
        {:tool_result, r} -> {texts, uses, results ++ [r]}
        :skip -> {texts, uses, results}
      end
    end)
  end

  defp classify_block(%{type: "text", text: t}), do: {:text, t}
  defp classify_block(%{"type" => "text", "text" => t}), do: {:text, t}

  defp classify_block(%{type: "tool_use", id: id, name: name} = b) do
    {:tool_use,
     %{
       id: id,
       type: "function",
       function: %{name: name, arguments: Jason.encode!(Map.get(b, :input, %{}))}
     }}
  end

  defp classify_block(%{"type" => "tool_use", "id" => id, "name" => name} = b) do
    {:tool_use,
     %{
       id: id,
       type: "function",
       function: %{name: name, arguments: Jason.encode!(Map.get(b, "input", %{}))}
     }}
  end

  defp classify_block(%{type: "tool_result"} = b) do
    {:tool_result,
     %{
       id: Map.get(b, :tool_use_id) || Map.get(b, "tool_use_id"),
       content: stringify_tool_result_content(Map.get(b, :content) || Map.get(b, "content"))
     }}
  end

  defp classify_block(%{"type" => "tool_result"} = b) do
    {:tool_result,
     %{
       id: Map.get(b, "tool_use_id"),
       content: stringify_tool_result_content(Map.get(b, "content"))
     }}
  end

  # Images aren't passed to OpenRouter — most code-focused models there
  # can't handle them, and the upstream code path for vision tools is
  # Anthropic-only today. Drop silently rather than error.
  defp classify_block(%{type: "image"}), do: :skip
  defp classify_block(%{"type" => "image"}), do: :skip
  defp classify_block(_), do: :skip

  defp stringify_tool_result_content(content) when is_binary(content), do: content

  defp stringify_tool_result_content(content) when is_list(content) do
    Enum.map_join(content, "", fn
      %{type: "text", text: t} -> t
      %{"type" => "text", "text" => t} -> t
      _ -> ""
    end)
  end

  defp stringify_tool_result_content(_), do: ""

  defp openai_tools(nil), do: nil
  defp openai_tools([]), do: nil

  defp openai_tools(tools) when is_list(tools) do
    Enum.map(tools, fn t ->
      %{
        type: "function",
        function: %{
          name: t[:name] || t["name"],
          description: t[:description] || t["description"] || "",
          parameters: t[:input_schema] || t["input_schema"] || %{}
        }
      }
    end)
  end

  # --- OpenAI response → Anthropic-shaped response ---

  defp from_openai_response(%{"choices" => [choice | _], "usage" => usage} = _resp) do
    msg = choice["message"] || %{}
    content = msg["content"] || ""
    tool_calls = msg["tool_calls"] || []

    %{
      thinking: nil,
      text: if(content == "", do: nil, else: content),
      tool_use:
        Enum.map(tool_calls, fn tc ->
          %{
            id: tc["id"],
            name: get_in(tc, ["function", "name"]),
            input: decode_args(get_in(tc, ["function", "arguments"]))
          }
        end),
      stop_reason: map_finish_reason(choice["finish_reason"], tool_calls),
      usage: %{
        input_tokens: usage["prompt_tokens"] || 0,
        output_tokens: usage["completion_tokens"] || 0,
        cache_read: 0,
        cache_create: 0
      }
    }
  end

  defp from_openai_response(other), do: %{
    thinking: nil,
    text: nil,
    tool_use: [],
    stop_reason: "end_turn",
    usage: %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_create: 0},
    raw: other
  }

  defp decode_args(nil), do: %{}
  defp decode_args(""), do: %{}

  defp decode_args(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = m} -> m
      _ -> %{}
    end
  end

  defp decode_args(_), do: %{}

  # OpenAI finish reasons → Anthropic stop_reason vocabulary the runner
  # already knows. We collapse `tool_calls` to `tool_use` so the
  # runner's existing dispatch path works unchanged.
  defp map_finish_reason("tool_calls", _), do: "tool_use"
  defp map_finish_reason("stop", _), do: "end_turn"
  defp map_finish_reason("length", _), do: "max_tokens"
  defp map_finish_reason("content_filter", _), do: "end_turn"
  defp map_finish_reason(_, [_ | _]), do: "tool_use"
  defp map_finish_reason(_, _), do: "end_turn"

  # --- Helpers ---

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp base_url do
    Application.get_env(:golem, :openrouter_base_url, @base_url)
  end

  defp api_key! do
    var = Application.get_env(:golem, :openrouter_api_key_env, "OPENROUTER_API_KEY")

    System.get_env(var) ||
      raise "#{var} environment variable not set (configure via providers.openrouter.api_key_env)"
  end
end
