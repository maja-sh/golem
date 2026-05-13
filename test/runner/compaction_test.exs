defmodule Golem.Runner.CompactionTest do
  use ExUnit.Case, async: true

  alias Golem.Runner.Compaction

  describe "truncate_str/2" do
    test "short strings pass through" do
      assert Compaction.truncate_str("hello", 80) == "hello"
    end

    test "long strings are cut and suffixed with ..." do
      s = String.duplicate("a", 100)
      out = Compaction.truncate_str(s, 20)
      assert String.length(out) == 20
      assert String.ends_with?(out, "...")
    end

    test "counts codepoints, not bytes" do
      # Japanese: 10 codepoints, 30 bytes
      s = "負傷あり負傷あり負傷"
      assert String.length(s) == 10
      assert Compaction.truncate_str(s, 20) == s
      assert String.length(Compaction.truncate_str(s, 8)) == 8
    end

    test "non-binary input is stringified" do
      assert Compaction.truncate_str(42, 10) == "42"
    end
  end

  describe "estimate_text_tokens/1" do
    test "ASCII text approx 3 chars per token" do
      assert Compaction.estimate_text_tokens("hello world") == div(11, 3)
    end

    test "unicode counted by codepoint, not byte" do
      # Japanese: 4 codepoints, 12 bytes — ends up as div(4, 3) = 1 token
      assert Compaction.estimate_text_tokens("負傷あり") == 1
    end

    test "empty string" do
      assert Compaction.estimate_text_tokens("") == 0
    end

    test "nil is zero, not a crash" do
      assert Compaction.estimate_text_tokens(nil) == 0
    end
  end

  describe "estimate_messages_tokens/1" do
    test "sums across messages" do
      msgs = [
        %{role: "user", content: "hello"},
        %{role: "assistant", content: "world"}
      ]

      assert Compaction.estimate_messages_tokens(msgs) ==
               Compaction.estimate_text_tokens("hello") +
                 Compaction.estimate_text_tokens("world")
    end

    test "handles block-list content with text blocks" do
      msgs = [
        %{
          role: "user",
          content: [
            %{type: "text", text: "a"},
            %{type: "text", text: "bbb"}
          ]
        }
      ]

      assert Compaction.estimate_messages_tokens(msgs) ==
               Compaction.estimate_text_tokens("a") + Compaction.estimate_text_tokens("bbb")
    end

    test "handles tool_result blocks" do
      msgs = [
        %{
          role: "user",
          content: [%{type: "tool_result", tool_use_id: "1", content: "output bytes"}]
        }
      ]

      assert Compaction.estimate_messages_tokens(msgs) ==
               Compaction.estimate_text_tokens("output bytes")
    end

    test "images contribute flat 2000 tokens" do
      msgs = [%{role: "user", content: [%{type: "image"}]}]
      assert Compaction.estimate_messages_tokens(msgs) == 2000
    end

    test "string-keyed blocks work too" do
      msgs = [
        %{
          "role" => "user",
          "content" => [%{"type" => "text", "text" => "hello"}]
        }
      ]

      assert Compaction.estimate_messages_tokens(msgs) ==
               Compaction.estimate_text_tokens("hello")
    end

    test "empty messages list is zero" do
      assert Compaction.estimate_messages_tokens([]) == 0
    end
  end
end
