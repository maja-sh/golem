defmodule Golem.E2E.ClaudeCacheTest do
  @moduledoc """
  End-to-end: verifies prompt caching works against the real Anthropic
  API. Requires `ANTHROPIC_API_KEY` to be set.

  Tagged `:e2e`, excluded by default. Run with:

      mix test.e2e
      mix test --only e2e
  """
  use ExUnit.Case, async: false

  @moduletag :e2e

  setup do
    unless System.get_env("ANTHROPIC_API_KEY") do
      raise "E2E tests require ANTHROPIC_API_KEY to be set"
    end

    :ok
  end

  test "prompt caching produces cache_read_input_tokens on the second turn" do
    # Unique marker so the cached prefix is specific to this test run.
    # Avoids interference from a warm cache populated by a prior run.
    marker = :erlang.unique_integer([:positive]) |> Integer.to_string()

    system = [
      %{
        type: "text",
        text: """
        You are a helpful assistant. Answer concisely with a single sentence.
        Run marker: #{marker}.
        #{String.duplicate("Context fragment. ", 500)}
        """,
        cache_control: %{type: "ephemeral"}
      }
    ]

    model = Application.get_env(:golem, :executor_model) || "claude-haiku-4-5"

    first = [%{role: "user", content: "say hello"}]

    {:ok, %{usage: u1}} =
      Golem.Claude.call(first,
        model: model,
        max_tokens: 50,
        system: system
      )

    # First call with a fresh marker should write the system prefix to
    # the cache.
    assert Map.get(u1, :cache_create, 0) > 0,
           "expected first call to populate cache, got #{inspect(u1)}"

    # Second call — different user message but same system prefix.
    second = [%{role: "user", content: "say goodbye"}]

    {:ok, %{usage: u2}} =
      Golem.Claude.call(second,
        model: model,
        max_tokens: 50,
        system: system
      )

    assert Map.get(u2, :cache_read, 0) > 0,
           "expected second call to hit cache, got #{inspect(u2)}"

    # cache_read should be close to the system prompt's token count.
    assert Map.get(u2, :cache_read) >= Map.get(u1, :cache_create) - 100
  end
end
