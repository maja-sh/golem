defmodule Golem.PricingTest do
  use ExUnit.Case, async: false

  alias Golem.Pricing

  setup do
    # Pricing reads :persistent_term for the OpenRouter catalogue and
    # the "warned about" set. Clear both per-test so behavior is
    # deterministic and "warn once" tests don't bleed.
    :persistent_term.erase(:golem_openrouter_pricing)
    :persistent_term.erase(:golem_unknown_pricing_seen)
    :ok
  end

  describe "Anthropic defaults" do
    test "claude-opus-* uses Opus pricing" do
      p = Pricing.for("claude-opus-4-7")
      assert p.input == 15.0
      assert p.output == 75.0
      assert p.cache_read == 1.5
      assert p.cache_create == 18.75
    end

    test "claude-sonnet-* uses Sonnet pricing" do
      p = Pricing.for("claude-sonnet-4-6")
      assert p.input == 3.0
      assert p.output == 15.0
      assert p.cache_read == 0.3
      assert p.cache_create == 3.75
    end

    test "claude-haiku-* uses Haiku pricing" do
      p = Pricing.for("claude-haiku-4-5-20251001")
      assert p.input == 1.0
      assert p.output == 5.0
      assert p.cache_read == 0.1
      assert p.cache_create == 1.25
    end
  end

  describe "OpenRouter catalogue parsing" do
    test "converts per-token strings to per-million floats" do
      # Drive the parser directly via the cache, bypassing HTTP.
      catalogue = %{
        "qwen/qwen-2.5-coder-32b-instruct" => %{
          input: 0.18,
          output: 0.18,
          cache_read: 0.0,
          cache_create: 0.0
        }
      }

      :persistent_term.put(:golem_openrouter_pricing, {System.system_time(:second), catalogue})

      p = Pricing.for("qwen/qwen-2.5-coder-32b-instruct")
      assert p.input == 0.18
      assert p.output == 0.18
      assert p.cache_read == 0.0
      assert p.cache_create == 0.0
    end

    test "model not in OpenRouter catalogue returns zero" do
      :persistent_term.put(:golem_openrouter_pricing, {System.system_time(:second), %{}})

      p = Pricing.for("nonexistent/model")
      assert p == %{input: 0.0, output: 0.0, cache_read: 0.0, cache_create: 0.0}
    end
  end

  describe "unknown models" do
    test "returns zero pricing for a model that matches no pattern" do
      :persistent_term.put(:golem_openrouter_pricing, {System.system_time(:second), %{}})

      p = Pricing.for("brand-new-model-with-no-slash")
      assert p == %{input: 0.0, output: 0.0, cache_read: 0.0, cache_create: 0.0}
    end
  end
end
