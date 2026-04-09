defmodule Penbot.TUITest do
  use ExUnit.Case, async: false

  describe "format_elapsed" do
    test "milliseconds" do
      assert Penbot.TUI.format_elapsed(42) == "42ms"
      assert Penbot.TUI.format_elapsed(999) == "999ms"
    end

    test "seconds" do
      assert Penbot.TUI.format_elapsed(1000) == "1.0s"
      assert Penbot.TUI.format_elapsed(1500) == "1.5s"
      assert Penbot.TUI.format_elapsed(42_000) == "42.0s"
    end

    test "nil" do
      assert Penbot.TUI.format_elapsed(nil) == "..."
    end
  end

  describe "format_tokens" do
    test "small numbers" do
      assert Penbot.TUI.format_tokens(500) == "500 tokens"
    end

    test "thousands" do
      assert Penbot.TUI.format_tokens(1500) == "1.5k tokens"
      assert Penbot.TUI.format_tokens(42_000) == "42.0k tokens"
    end

    test "zero and nil" do
      assert Penbot.TUI.format_tokens(0) == ""
      assert Penbot.TUI.format_tokens(nil) == ""
    end
  end
end
