defmodule Golem.ClaudeTest do
  use ExUnit.Case, async: true

  alias Golem.Claude

  describe "is_reminder?/1" do
    test "atom-keyed reminder message" do
      assert Claude.is_reminder?(%{role: "user", content: "<system-reminder>\nhi\n</system-reminder>"})
    end

    test "string-keyed reminder message" do
      assert Claude.is_reminder?(%{"role" => "user", "content" => "<system-reminder>\nhi"})
    end

    test "non-reminder user message" do
      refute Claude.is_reminder?(%{role: "user", content: "hello"})
    end

    test "message with block-list content is not a reminder (binary content only)" do
      msg = %{role: "user", content: [%{type: "text", text: "<system-reminder>"}]}
      refute Claude.is_reminder?(msg)
    end

    test "non-map input" do
      refute Claude.is_reminder?(nil)
      refute Claude.is_reminder?("string")
    end
  end

  describe "add_cache_breakpoints/1" do
    test "empty messages list" do
      assert Claude.add_cache_breakpoints([]) == []
    end

    test "marks last user message's last content block" do
      messages = [
        %{role: "user", content: [%{type: "text", text: "goal"}]},
        %{role: "assistant", content: [%{type: "text", text: "ok"}]},
        %{role: "user", content: [%{type: "text", text: "follow up"}]}
      ]

      [_, _, last] = Claude.add_cache_breakpoints(messages)
      [block] = last.content
      assert block.cache_control == %{type: "ephemeral"}
    end

    test "skips reminder messages when choosing the breakpoint target" do
      messages = [
        %{role: "user", content: [%{type: "text", text: "goal"}]},
        %{role: "assistant", content: [%{type: "text", text: "ok"}]},
        %{role: "user", content: [%{type: "text", text: "tool result here"}]},
        %{role: "user", content: "<system-reminder>\nstate\n</system-reminder>"}
      ]

      [_, _, tool_result_user, reminder] = Claude.add_cache_breakpoints(messages)

      # Tool result is the last non-reminder user message → gets cache_control
      [block] = tool_result_user.content
      assert block.cache_control == %{type: "ephemeral"}

      # Reminder content stays untouched (a plain string, no cache_control)
      assert reminder.content == "<system-reminder>\nstate\n</system-reminder>"
    end

    test "no user messages → no change" do
      messages = [%{role: "assistant", content: [%{type: "text", text: "hi"}]}]
      assert Claude.add_cache_breakpoints(messages) == messages
    end

    test "works with string-keyed messages" do
      messages = [
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "goal"}]}
      ]

      [msg] = Claude.add_cache_breakpoints(messages)
      [block] = msg["content"]
      assert block.cache_control == %{type: "ephemeral"}
    end
  end

  describe "cache_last_tool/1" do
    test "marks the last tool in the list" do
      tools = [
        %{name: "a", description: "x"},
        %{name: "b", description: "y"},
        %{name: "c", description: "z"}
      ]

      [a, b, c] = Claude.cache_last_tool(tools)
      refute Map.has_key?(a, :cache_control)
      refute Map.has_key?(b, :cache_control)
      assert c.cache_control == %{type: "ephemeral"}
    end

    test "single tool is marked" do
      [tool] = Claude.cache_last_tool([%{name: "only"}])
      assert tool.cache_control == %{type: "ephemeral"}
    end
  end
end
