defmodule Golem.Runner.CompactionTest do
  use ExUnit.Case, async: true

  alias Golem.Runner.Compaction

  describe "build_cleared_signature/2" do
    test "shell with exit code 0 marks ok" do
      entry = %{name: "shell", input: %{"command" => "ls /home"}}
      sig = Compaction.build_cleared_signature(entry, "file1\nfile2\nfile3")
      assert sig =~ ~s([cleared: shell "ls /home" → ok, 17B])
    end

    test "shell with non-zero exit code preserves the code" do
      entry = %{name: "shell", input: %{"command" => "npm run build"}}
      content = "[exit code 137]\n" <> String.duplicate("out\n", 600)
      sig = Compaction.build_cleared_signature(entry, content)
      assert sig =~ ~s(shell "npm run build")
      assert sig =~ "→ exit 137"
      assert sig =~ "KB]"
    end

    test "shell stalled" do
      entry = %{name: "shell", input: %{"command" => "sleep 300"}}
      content = "[command stalled — no output for 120s, partial: 0 bytes]"
      sig = Compaction.build_cleared_signature(entry, content)
      assert sig =~ "→ stalled"
    end

    test "shell timed out" do
      entry = %{name: "shell", input: %{"command" => "slow-thing"}}
      content = "[command timed out]\npartial"
      sig = Compaction.build_cleared_signature(entry, content)
      assert sig =~ "→ timed out"
    end

    test "read_file shows path, no status" do
      entry = %{name: "read_file", input: %{"path" => "/home/agent/src/main.js"}}
      content = String.duplicate("line\n", 10_000)
      sig = Compaction.build_cleared_signature(entry, content)
      assert sig =~ "[cleared: read_file /home/agent/src/main.js"
      refute sig =~ "→"
    end

    test "grep shows quoted pattern" do
      entry = %{name: "grep", input: %{"pattern" => "has_injury"}}
      sig = Compaction.build_cleared_signature(entry, String.duplicate("x", 5000))
      assert sig =~ ~s(grep "has_injury")
    end

    test "web_search shows quoted query" do
      entry = %{name: "web_search", input: %{"query" => "vue translation patterns"}}
      sig = Compaction.build_cleared_signature(entry, String.duplicate("x", 2000))
      assert sig =~ ~s(web_search "vue translation patterns")
    end

    test "unknown tool omits input_str" do
      entry = %{name: "mystery_tool", input: %{"whatever" => "x"}}
      sig = Compaction.build_cleared_signature(entry, String.duplicate("x", 500))
      assert sig =~ "[cleared: mystery_tool,"
      refute sig =~ "mystery_tool "
    end

    test "content prefixed with [error] classifies as error for non-shell tools" do
      entry = %{name: "read_file", input: %{"path" => "/missing"}}
      sig = Compaction.build_cleared_signature(entry, "[error] not found" <> String.duplicate("x", 300))
      assert sig =~ "→ error"
    end

    test "preserves spill path so the model can still re-read the full output" do
      entry = %{name: "shell", input: %{"command" => "phpunit"}}

      content = """
      <persisted-output path="/tmp/golem-spill-toolu_01abc.txt">
      Output too large (80.0 KB). Saved to /tmp/golem-spill-toolu_01abc.txt.
      Use `read_file` with path="/tmp/golem-spill-toolu_01abc.txt" ...

      Preview (first 2 KB):
      PHPUnit 10.x
      """ <> String.duplicate("test output line\n", 500)

      sig = Compaction.build_cleared_signature(entry, content)
      assert sig =~ "spilled at /tmp/golem-spill-toolu_01abc.txt"
    end

    test "omits spill note when content was never spilled" do
      entry = %{name: "shell", input: %{"command" => "echo hi"}}
      sig = Compaction.build_cleared_signature(entry, "hi\n" <> String.duplicate("x", 500))
      refute sig =~ "spilled at"
    end
  end

  describe "extract_status_hint/2" do
    test "shell with zero exit falls through to ok" do
      assert Compaction.extract_status_hint("shell", "file1\nfile2") == "ok"
    end

    test "shell with malformed exit line is failed" do
      assert Compaction.extract_status_hint("shell", "[exit code X]\n") == "failed"
    end

    test "returns empty for non-shell, non-error content" do
      assert Compaction.extract_status_hint("read_file", "some file content") == ""
    end
  end

  describe "format_size/1" do
    test "bytes" do
      assert Compaction.format_size(0) == "0B"
      assert Compaction.format_size(42) == "42B"
      assert Compaction.format_size(1023) == "1023B"
    end

    test "kilobytes" do
      assert Compaction.format_size(1024) == "1.0KB"
      assert Compaction.format_size(2355) == "2.3KB"
      assert Compaction.format_size(1024 * 1024 - 1) == "1024.0KB"
    end

    test "megabytes" do
      assert Compaction.format_size(1024 * 1024) == "1.0MB"
      assert Compaction.format_size(5 * 1024 * 1024 + 512 * 1024) == "5.5MB"
    end
  end

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

  describe "summarize_tool_input/2" do
    test "shell returns quoted command" do
      assert Compaction.summarize_tool_input("shell", %{"command" => "ls"}) == ~s("ls")
    end

    test "truncates very long shell commands" do
      cmd = String.duplicate("x", 200)
      out = Compaction.summarize_tool_input("shell", %{"command" => cmd})
      assert String.length(out) == 80 + 2  # quoted + truncated
    end

    test "unknown tool returns empty" do
      assert Compaction.summarize_tool_input("weird_tool", %{}) == ""
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
