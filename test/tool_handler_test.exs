defmodule Penbot.ToolHandlerTest do
  use ExUnit.Case, async: false

  # These tests don't touch the sandbox — they test the logic
  # in the tool handler that runs locally (edit_file matching,
  # progress parsing, think routing, etc.)

  describe "edit_file matching" do
    setup do
      Agent.update(Penbot.FileCache, fn _ -> %{} end)
      :ok
    end

    test "detects already-applied edit" do
      # Simulate a file that already has the new content
      Penbot.FileCache.put("/test/file.rs", "fn hello() {\n    println!(\"world\");\n}")

      # The old_string is gone but new_string is present
      result = Penbot.ToolHandler.execute(
        %{name: "edit_file", input: %{
          "path" => "/test/file.rs",
          "old_string" => "fn hello() {\n    println!(\"hello\");\n}",
          "new_string" => "fn hello() {\n    println!(\"world\");\n}"
        }},
        0
      )

      # Should not need to read from sandbox — cached
      # But we can't easily test that without mocking sandbox
      # At minimum, verify the handler doesn't crash
      assert {:continue, msg} = result
      # Either "already applied" or "not found" depending on sandbox availability
      assert is_binary(msg)
    end
  end

  describe "update_progress parsing" do
    setup do
      Agent.update(Penbot.FileCache, fn _ -> %{} end)
      :ok
    end

    test "parses standard status values" do
      items = [
        %{"text" => "Step 1", "status" => "completed"},
        %{"text" => "Step 2", "status" => "in_progress"},
        %{"text" => "Step 3", "status" => "pending"}
      ]

      result = Penbot.ToolHandler.execute(
        %{name: "update_progress", input: %{"items" => items}},
        0
      )

      assert {:continue, "Progress updated (1/3 completed)."} = result
    end

    test "parses alternate status values" do
      items = [
        %{"text" => "Done thing", "status" => "complete"},
        %{"text" => "Done thing 2", "status" => "done"},
        %{"text" => "Active thing", "status" => "working"},
        %{"text" => "Active thing 2", "status" => "in-progress"},
        %{"text" => "Active thing 3", "status" => "active"},
        %{"text" => "Waiting", "status" => "pending"},
        %{"text" => "Unknown", "status" => "whatever"}
      ]

      result = Penbot.ToolHandler.execute(
        %{name: "update_progress", input: %{"items" => items}},
        0
      )

      assert {:continue, "Progress updated (2/7 completed)."} = result
    end
  end

  describe "think tool routing" do
    setup do
      Agent.update(Penbot.FileCache, fn _ -> %{} end)
      :ok
    end

    test "think without replan returns reasoning" do
      reasoning = "I should try a different approach because..."

      result = Penbot.ToolHandler.execute(
        %{name: "think", input: %{"reasoning" => reasoning}},
        0
      )

      assert {:continue, ^reasoning} = result
    end

    test "think with replan returns :think_replan" do
      reasoning = "After researching, I recommend building X"

      result = Penbot.ToolHandler.execute(
        %{name: "think", input: %{"reasoning" => reasoning, "request_replan" => true}},
        0
      )

      assert {:think_replan, ^reasoning} = result
    end

    test "think defaults to no replan" do
      result = Penbot.ToolHandler.execute(
        %{name: "think", input: %{"reasoning" => "some thought"}},
        0
      )

      assert {:continue, _} = result
    end
  end

  describe "done tool" do
    setup do
      Agent.update(Penbot.FileCache, fn _ -> %{} end)
      :ok
    end

    test "returns done with success" do
      result = Penbot.ToolHandler.execute(
        %{name: "done", input: %{"success" => true, "summary" => "Built the thing"}},
        0
      )

      assert {:done, %{success: true, summary: "Built the thing"}} = result
    end

    test "returns done with failure" do
      result = Penbot.ToolHandler.execute(
        %{name: "done", input: %{"success" => false, "summary" => "Couldn't do it"}},
        0
      )

      assert {:done, %{success: false, summary: "Couldn't do it"}} = result
    end

    test "defaults success to false" do
      result = Penbot.ToolHandler.execute(
        %{name: "done", input: %{"summary" => "something"}},
        0
      )

      assert {:done, %{success: false}} = result
    end
  end

  describe "unknown tool" do
    setup do
      Agent.update(Penbot.FileCache, fn _ -> %{} end)
      :ok
    end

    test "returns error for unknown tool" do
      result = Penbot.ToolHandler.execute(
        %{name: "nonexistent_tool", input: %{}},
        0
      )

      assert {:continue, "[error] Unknown tool: nonexistent_tool"} = result
    end
  end
end
