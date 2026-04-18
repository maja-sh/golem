defmodule Golem.Runner.SpillTest do
  use ExUnit.Case, async: true

  alias Golem.Runner.Spill

  defp tc(name, id \\ "toolu_01abc"), do: %{name: name, id: id}

  describe "plan/2 — passthrough cases" do
    test "content below threshold stays inline" do
      content = String.duplicate("x", Spill.threshold_bytes() - 1)
      assert Spill.plan(content, tc("shell")) == :passthrough
    end

    test "content exactly at threshold stays inline" do
      content = String.duplicate("x", Spill.threshold_bytes())
      assert Spill.plan(content, tc("shell")) == :passthrough
    end

    test "large output from a non-spillable tool stays inline" do
      large = String.duplicate("x", Spill.threshold_bytes() * 2)

      for name <- ~w(write_file edit_file think done update_progress sub_agent) do
        assert Spill.plan(large, tc(name)) == :passthrough,
               "expected #{name} to pass through"
      end
    end

    test "non-binary content is ignored" do
      assert Spill.plan(nil, tc("shell")) == :passthrough
      assert Spill.plan([1, 2, 3], tc("shell")) == :passthrough
      assert Spill.plan(%{some: "map"}, tc("shell")) == :passthrough
    end

    test "every whitelisted tool name is actually spillable" do
      large = String.duplicate("x", Spill.threshold_bytes() * 2)

      for name <- Spill.spillable_tools() do
        assert match?({:spill, _, _}, Spill.plan(large, tc(name))),
               "expected #{name} to spill"
      end
    end
  end

  describe "plan/2 — spill cases" do
    test "returns spill tuple with deterministic path" do
      large = String.duplicate("x", Spill.threshold_bytes() + 1)
      assert {:spill, path, _msg} = Spill.plan(large, tc("shell", "toolu_01xyz"))
      assert path == "/tmp/golem-spill-toolu_01xyz.txt"
    end

    test "preview message embeds the spill path and size" do
      large = String.duplicate("x", 50_000)
      {:spill, path, msg} = Spill.plan(large, tc("shell", "toolu_abc"))

      assert msg =~ ~s(<persisted-output path="#{path}">)
      assert msg =~ "Saved to #{path}"
      assert msg =~ ~s(read_file` with path="#{path}")
      assert msg =~ "48.8 KB"
    end

    test "preview is capped at preview_bytes" do
      large = String.duplicate("a", 100_000)
      {:spill, _path, msg} = Spill.plan(large, tc("shell"))

      # The message itself has a ~200-byte wrapper; the preview content
      # inside must not exceed preview_bytes.
      [_prefix, after_preview] = String.split(msg, "Preview (first 1 KB):\n", parts: 2)
      [preview_only, _tail] = String.split(after_preview, "\n</persisted-output>", parts: 2)

      assert byte_size(preview_only) <= Spill.preview_bytes()
    end

    test "preview trims on a UTF-8 boundary, not mid-codepoint" do
      # 😀 is 4 bytes. Build content that would force a trim in the middle
      # of that emoji if the helper weren't boundary-aware.
      head = String.duplicate("a", Spill.preview_bytes() - 2)
      content = head <> "😀" <> String.duplicate("b", 20_000)

      {:spill, _path, msg} = Spill.plan(content, tc("shell"))

      # The resulting message must be valid UTF-8 (would crash otherwise
      # when logged or sent to the API).
      assert String.valid?(msg)
    end

    test "spill path uses the tool_use_id verbatim" do
      large = String.duplicate("x", 20_000)
      {:spill, path, _msg} = Spill.plan(large, tc("read_file", "toolu_99"))
      assert path == "/tmp/golem-spill-toolu_99.txt"
    end

    test "empty-id edge case still produces a usable (if ugly) path" do
      large = String.duplicate("x", 20_000)
      {:spill, path, _msg} = Spill.plan(large, tc("shell", ""))
      assert path == "/tmp/golem-spill-.txt"
    end
  end
end
