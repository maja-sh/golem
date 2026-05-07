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

  test "prompt caching produces cache_read on back-to-back calls with the same prefix" do
    # Use a unique token marker so a cache warmed by a prior run doesn't
    # make turn 1 look like a cache hit instead of a write.
    marker = :erlang.unique_integer([:positive]) |> Integer.to_string()

    # Anthropic requires ≥1024 tokens for cacheable content on Sonnet 4.x.
    # 500 reps lands around 1500 tokens — close to the threshold and seen
    # to come back uncached in practice. 1500 reps clears it with margin.
    system = [
      %{
        type: "text",
        text:
          "You are a helpful assistant. marker=#{marker} " <>
            String.duplicate("Context fragment. ", 1500),
        cache_control: %{type: "ephemeral"}
      }
    ]

    model = Application.get_env(:golem, :executor_model) || "claude-haiku-4-5"

    {:ok, %{usage: u1}} =
      Golem.Claude.call([%{role: "user", content: "hi"}],
        model: model,
        max_tokens: 50,
        system: system
      )

    assert Map.get(u1, :cache_create, 0) > 0,
           "expected first call to populate cache, got #{inspect(u1)}"

    {:ok, %{usage: u2}} =
      Golem.Claude.call([%{role: "user", content: "bye"}],
        model: model,
        max_tokens: 50,
        system: system
      )

    assert Map.get(u2, :cache_read, 0) > 0,
           "expected second call to hit cache, got #{inspect(u2)}"
  end
end
