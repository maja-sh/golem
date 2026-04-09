defmodule Golem.TUITest do
  use ExUnit.Case, async: false

  describe "format_elapsed" do
    test "milliseconds" do
      assert Golem.TUI.format_elapsed(42) == "42ms"
      assert Golem.TUI.format_elapsed(999) == "999ms"
    end

    test "seconds" do
      assert Golem.TUI.format_elapsed(1000) == "1.0s"
      assert Golem.TUI.format_elapsed(1500) == "1.5s"
      assert Golem.TUI.format_elapsed(42_000) == "42.0s"
    end

    test "nil" do
      assert Golem.TUI.format_elapsed(nil) == "..."
    end
  end

  describe "format_tokens" do
    test "small numbers" do
      assert Golem.TUI.format_tokens(500) == "500 tokens"
    end

    test "thousands" do
      assert Golem.TUI.format_tokens(1500) == "1.5k tokens"
      assert Golem.TUI.format_tokens(42_000) == "42.0k tokens"
    end

    test "zero and nil" do
      assert Golem.TUI.format_tokens(0) == ""
      assert Golem.TUI.format_tokens(nil) == ""
    end
  end
end
