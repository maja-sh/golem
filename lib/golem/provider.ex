defmodule Golem.Provider do
  @moduledoc """
  Behaviour every LLM backend implements so the runner can target it
  through a single `Golem.LLM.call/2` entrypoint. The response shape is
  Anthropic-flavored (it's what the runner was originally built around)
  — providers that don't natively speak it translate their own response
  into this shape.

  Fields the runner reads:

    * `:thinking`     — extended-thinking text, or `nil` when unsupported
    * `:text`         — concatenated text output, or `nil` when none
    * `:tool_use`     — list of `%{id, name, input}` tool calls
    * `:stop_reason`  — string. The runner cares about `"tool_use"`,
                        `"end_turn"`, `"max_tokens"`, `"pause_turn"`
    * `:usage`        — `%{input_tokens, output_tokens, cache_read,
                        cache_create}` (cache values are 0 when the
                        provider doesn't bill that way)

  Capabilities that some providers don't support (`thinking`,
  `cache_control`, etc.) are silently ignored in their respective
  implementations — the caller doesn't have to gate on provider type.
  """

  @type response :: %{
          thinking: nil | String.t(),
          text: nil | String.t(),
          tool_use: [%{id: String.t(), name: String.t(), input: map()}],
          stop_reason: String.t(),
          usage: %{
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            cache_read: non_neg_integer(),
            cache_create: non_neg_integer()
          }
        }

  @callback call(messages :: list(), opts :: keyword()) ::
              {:ok, response()} | {:error, term()}
end
