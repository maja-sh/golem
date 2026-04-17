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

  describe "format_duration" do
    test "under a minute" do
      assert Golem.TUI.format_duration(0) == "0s"
      assert Golem.TUI.format_duration(42) == "42s"
    end

    test "whole minutes omit the seconds part" do
      assert Golem.TUI.format_duration(60) == "1m"
      assert Golem.TUI.format_duration(120) == "2m"
    end

    test "mixed minutes and seconds" do
      assert Golem.TUI.format_duration(65) == "1m 5s"
      assert Golem.TUI.format_duration(3665) == "61m 5s"
    end
  end

  describe "wrap_text" do
    test "short text stays on one line" do
      assert Golem.TUI.wrap_text("hello world", 40) == ["hello world"]
    end

    test "long text wraps at word boundaries" do
      text = "the quick brown fox jumps over the lazy dog"
      assert Golem.TUI.wrap_text(text, 15) == [
               "the quick brown",
               "fox jumps over",
               "the lazy dog"
             ]
    end

    test "handles embedded newlines" do
      assert Golem.TUI.wrap_text("first line\nsecond line", 40) == [
               "first line",
               "second line"
             ]
    end

    test "width under 10 returns text as a single item" do
      assert Golem.TUI.wrap_text("anything here", 5) == ["anything here"]
    end
  end

  describe "truncate_visible" do
    test "keeps ANSI escapes intact while counting visible chars only" do
      input = "\e[31mhello world\e[0m"
      # max_width 5 → keep "hello" visible
      out = Golem.TUI.truncate_visible(input, 5)
      assert out =~ "\e[31m"
      assert out =~ "hello"
      refute out =~ "world"
    end

    test "preserves full string when it fits" do
      input = "\e[32mgreen\e[0m"
      out = Golem.TUI.truncate_visible(input, 50)
      assert out == input <> "\e[0m"
    end

    test "plain strings are truncated by character count" do
      out = Golem.TUI.truncate_visible("abcdefghij", 4)
      # "abcd" + reset
      assert out == "abcd\e[0m"
    end

    test "zero width drops all visible content but keeps escapes" do
      out = Golem.TUI.truncate_visible("\e[31mhello\e[0m", 0)
      assert out =~ "\e[31m"
      refute out =~ "hello"
    end
  end

  describe "tool_icon" do
    test "known tools have distinct icons" do
      assert Golem.TUI.tool_icon("shell") == "$"
      assert Golem.TUI.tool_icon("write_file") == "+"
      assert Golem.TUI.tool_icon("read_file") == "↓"
      assert Golem.TUI.tool_icon("edit_file") == "~"
      assert Golem.TUI.tool_icon("grep") == "⌕"
      assert Golem.TUI.tool_icon("done") == "✓"
    end

    test "unknown tool falls back" do
      assert Golem.TUI.tool_icon("mystery_tool") == "▸"
    end
  end

  describe "tool_label" do
    test "path-based tools include the path" do
      assert Golem.TUI.tool_label("read_file", "/foo/bar.ex") == "Read /foo/bar.ex"
      assert Golem.TUI.tool_label("write_file", "/x.ex") == "Write /x.ex"
      assert Golem.TUI.tool_label("edit_file", "/x.ex") == "Edit /x.ex"
    end

    test "static labels for session verbs" do
      assert Golem.TUI.tool_label("think", "anything") == "Thinking..."
      assert Golem.TUI.tool_label("done", nil) == "Done"
      assert Golem.TUI.tool_label("update_progress", "ignored") == "Progress update"
    end

    test "unknown tool returns the name as label" do
      assert Golem.TUI.tool_label("mystery_tool", "whatever") == "mystery_tool"
    end
  end
end
