defmodule Golem.Claude do
  @moduledoc """
  Claude API client. Supports tool use with extended thinking.
  """

  require Logger

  @base_url "https://api.anthropic.com/v1"
  @max_retries 10
  @initial_backoff_ms 2_000
  @max_backoff_ms 120_000
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
    model = opts[:model] || Application.get_env(:golem, :executor_model)
    max_tokens = opts[:max_tokens] || Application.get_env(:golem, :executor_max_tokens)
    system = opts[:system]
    tools = opts[:tools]
    thinking_budget = opts[:thinking_budget]

    # Normalize messages: the API requires content to be a list of blocks
    # when any message in the conversation uses block format (tool_use/tool_result).
    # System injections use plain strings, so convert them here.
    # Drop messages with nil/empty content — they're invalid.
    normalized =
      messages
      |> Enum.reject(&empty_message?/1)
      |> Enum.map(&normalize_message/1)
      |> add_cache_breakpoints()

    body =
      %{model: model, max_tokens: max_tokens, messages: normalized}
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

  @doc """
  Call Claude with streaming. Text tokens are sent to `on_text` callback
  as they arrive. Returns the same {:ok, response} as `call/2`.

  Options:
  - :on_text — fn(text_chunk) called for each text delta
  """
  def call_stream(messages, opts \\ []) do
    api_key = api_key!()
    model = opts[:model] || Application.get_env(:golem, :executor_model)
    max_tokens = opts[:max_tokens] || Application.get_env(:golem, :executor_max_tokens)
    system = opts[:system]
    tools = opts[:tools]
    thinking_budget = opts[:thinking_budget]
    on_text = opts[:on_text] || fn _ -> :ok end

    body =
      %{model: model, max_tokens: max_tokens, messages: messages, stream: true}
      |> maybe_put(:system, system)
      |> maybe_put(:tools, tools)
      |> maybe_put_thinking(thinking_budget)

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    do_call_stream(body, headers, model, on_text, 0)
  end

  defp do_call_stream(body, headers, model, on_text, attempt) do
    start = System.monotonic_time(:millisecond)

    # Accumulator for SSE parsing
    acc = %{
      buffer: "",
      blocks: %{},       # index => %{type, id, name, text, input_json}
      current_idx: nil,
      usage: %{},
      stop_reason: "end_turn",
      on_text: on_text
    }

    stream_fun = fn {:data, chunk}, {req, resp} ->
      # Process might receive multiple SSE events in one chunk
      Process.put(:sse_acc, process_sse_chunk(chunk, Process.get(:sse_acc, acc)))
      {:cont, {req, resp}}
    end

    Process.put(:sse_acc, acc)

    result =
      Req.post("#{@base_url}/messages",
        json: body,
        headers: headers,
        retry: false,
        receive_timeout: 180_000,
        into: stream_fun
      )

    final_acc = Process.get(:sse_acc, acc)
    Process.delete(:sse_acc)

    case result do
      {:ok, %{status: 200}} ->
        elapsed = System.monotonic_time(:millisecond) - start
        response = build_response_from_stream(final_acc)

        usage = response.usage
        cache_read = Map.get(usage, :cache_read, 0)
        cache_create = Map.get(usage, :cache_create, 0)
        cache_info = if cache_read > 0 or cache_create > 0,
          do: " (cache: #{cache_read} read, #{cache_create} create)", else: ""

        Logger.info(
          "Claude #{model} — #{elapsed}ms — #{usage.input_tokens} in / #{usage.output_tokens} out#{cache_info}"
        )

        {:ok, response}

      {:ok, %{status: status}} when status in @retryable_statuses ->
        elapsed = System.monotonic_time(:millisecond) - start
        if attempt < @max_retries do
          backoff = backoff_ms(attempt)
          Logger.warning("Claude stream #{status} after #{elapsed}ms — retry #{attempt + 1}/#{@max_retries}")
          Process.sleep(backoff)
          do_call_stream(body, headers, model, on_text, attempt + 1)
        else
          {:error, {status, "exhausted retries"}}
        end

      {:ok, %{status: status, body: resp}} ->
        Logger.error("Claude stream error #{status}: #{inspect(resp)}")
        {:error, {status, resp}}

      {:error, %Req.TransportError{}} when attempt < @max_retries ->
        backoff = backoff_ms(attempt)
        Logger.warning("Claude stream transport error — retry #{attempt + 1}/#{@max_retries}")
        Process.sleep(backoff)
        do_call_stream(body, headers, model, on_text, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- SSE Parsing ---

  defp process_sse_chunk(chunk, acc) do
    # Buffer may contain partial lines from previous chunk
    data = acc.buffer <> chunk

    # Split into lines, keeping the last (possibly incomplete) line as buffer
    lines = String.split(data, "\n")
    {complete, [remainder]} = Enum.split(lines, -1)

    acc = %{acc | buffer: remainder}

    Enum.reduce(complete, acc, fn line, acc ->
      case line do
        "data: " <> json_str ->
          case Jason.decode(json_str) do
            {:ok, event} -> handle_sse_event(event, acc)
            _ -> acc
          end
        _ -> acc
      end
    end)
  end

  defp handle_sse_event(%{"type" => "content_block_start", "index" => idx, "content_block" => block}, acc) do
    block_info = %{
      type: block["type"],
      id: block["id"],
      name: block["name"],
      text: "",
      input_json: ""
    }
    put_in(acc, [:blocks, idx], block_info)
    |> Map.put(:current_idx, idx)
  end

  defp handle_sse_event(%{"type" => "content_block_delta", "index" => idx, "delta" => delta}, acc) do
    case delta["type"] do
      "text_delta" ->
        text = delta["text"] || ""
        acc.on_text.(text)
        update_in(acc, [:blocks, idx, :text], &(&1 <> text))

      "input_json_delta" ->
        json = delta["partial_json"] || ""
        update_in(acc, [:blocks, idx, :input_json], &(&1 <> json))

      "thinking_delta" ->
        thinking = delta["thinking"] || ""
        update_in(acc, [:blocks, idx, :text], &(&1 <> thinking))

      _ -> acc
    end
  end

  defp handle_sse_event(%{"type" => "message_start", "message" => msg}, acc) do
    usage = Map.get(msg, "usage", %{})
    %{acc | usage: Map.merge(acc.usage, usage)}
  end

  defp handle_sse_event(%{"type" => "message_delta", "delta" => delta, "usage" => usage}, acc) do
    stop_reason = Map.get(delta, "stop_reason", acc.stop_reason)
    %{acc | stop_reason: stop_reason, usage: Map.merge(acc.usage, usage || %{})}
  end

  defp handle_sse_event(_event, acc), do: acc

  defp build_response_from_stream(acc) do
    blocks = acc.blocks |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

    thinking =
      blocks
      |> Enum.filter(&(&1.type == "thinking"))
      |> Enum.map_join("\n", & &1.text)
      |> case do
        "" -> nil
        t -> t
      end

    text =
      blocks
      |> Enum.filter(&(&1.type == "text"))
      |> Enum.map_join("\n", & &1.text)
      |> case do
        "" -> nil
        t -> t
      end

    tool_use =
      blocks
      |> Enum.filter(&(&1.type == "tool_use"))
      |> Enum.map(fn block ->
        input = case Jason.decode(block.input_json) do
          {:ok, parsed} -> parsed
          _ -> %{}
        end
        %{id: block.id, name: block.name, input: input}
      end)

    usage = acc.usage
    %{
      thinking: thinking,
      text: text,
      tool_use: tool_use,
      stop_reason: acc.stop_reason,
      usage: %{
        input_tokens: Map.get(usage, "input_tokens", 0),
        output_tokens: Map.get(usage, "output_tokens", 0),
        cache_read: Map.get(usage, "cache_read_input_tokens", 0),
        cache_create: Map.get(usage, "cache_creation_input_tokens", 0)
      }
    }
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
    # Exponential backoff with jitter, capped at max
    # 2s, 4s, 8s, 16s, 32s, 64s, 120s, 120s, 120s, 120s
    base = (@initial_backoff_ms * :math.pow(2, attempt)) |> round() |> min(@max_backoff_ms)
    jitter = :rand.uniform(2_000)
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

  defp empty_message?(%{content: nil}), do: true
  defp empty_message?(%{"content" => nil}), do: true
  defp empty_message?(%{content: ""}), do: true
  defp empty_message?(%{"content" => ""}), do: true
  defp empty_message?(%{content: []}), do: true
  defp empty_message?(%{"content" => []}), do: true
  defp empty_message?(_), do: false

  # Normalize a message so content is always a list of blocks.
  # The API rejects string content when other messages use block format.
  defp normalize_message(%{content: content} = msg) when is_binary(content) do
    %{msg | content: [%{type: "text", text: content}]}
  end

  defp normalize_message(%{"content" => content} = msg) when is_binary(content) do
    Map.put(msg, "content", [%{"type" => "text", "text" => content}])
  end

  defp normalize_message(msg), do: msg

  # Add cache_control breakpoint to the last content block of the last
  # user message. This caches the entire conversation prefix so subsequent
  # turns only pay for new tokens. No context is lost — Claude sees the
  # same conversation, Anthropic just serves cached tokens at 90% discount.
  #
  # Skips per-turn system-reminder messages (they change every turn and
  # would defeat caching). The breakpoint goes on the last *non-reminder*
  # user message — typically the tool_result from the previous assistant
  # turn, which IS stable across turns.
  defp add_cache_breakpoints([]), do: []

  defp add_cache_breakpoints(messages) do
    last_user_idx =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _} ->
        role = msg[:role] || msg["role"]
        role == "user" and not is_reminder?(msg)
      end)
      |> List.last()

    case last_user_idx do
      {_msg, idx} ->
        List.update_at(messages, idx, &mark_last_block/1)

      nil ->
        messages
    end
  end

  defp is_reminder?(%{content: content}) when is_binary(content) do
    String.starts_with?(content, "<system-reminder>")
  end
  defp is_reminder?(%{"content" => content}) when is_binary(content) do
    String.starts_with?(content, "<system-reminder>")
  end
  defp is_reminder?(_), do: false

  defp mark_last_block(%{content: content} = msg) when is_list(content) and content != [] do
    updated = List.update_at(content, -1, &put_cache_control/1)
    %{msg | content: updated}
  end

  defp mark_last_block(%{"content" => content} = msg) when is_list(content) and content != [] do
    updated = List.update_at(content, -1, &put_cache_control/1)
    Map.put(msg, "content", updated)
  end

  defp mark_last_block(msg), do: msg

  defp put_cache_control(block) when is_map(block) do
    Map.put(block, :cache_control, %{type: "ephemeral"})
  end

  defp maybe_put(map, _key, nil), do: map

  # System prompt: wrap as cacheable content block
  defp maybe_put(map, :system, text) when is_binary(text) do
    Map.put(map, :system, [
      %{type: "text", text: text, cache_control: %{type: "ephemeral"}}
    ])
  end

  # Pre-built system blocks (static cached + dynamic uncached)
  defp maybe_put(map, :system, blocks) when is_list(blocks) do
    Map.put(map, :system, blocks)
  end

  # Tools: cache the whole array by marking the last tool with
  # cache_control. Tool definitions don't change within a run, so this
  # keeps them in the prompt cache across turns.
  defp maybe_put(map, :tools, tools) when is_list(tools) and tools != [] do
    Map.put(map, :tools, cache_last_tool(tools))
  end

  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp cache_last_tool(tools) do
    last_idx = length(tools) - 1
    List.update_at(tools, last_idx, fn tool ->
      Map.put(tool, :cache_control, %{type: "ephemeral"})
    end)
  end

  defp maybe_put_thinking(body, nil), do: body

  defp maybe_put_thinking(body, budget) do
    body
    |> Map.put(:thinking, %{type: "enabled", budget_tokens: budget})
  end
end
