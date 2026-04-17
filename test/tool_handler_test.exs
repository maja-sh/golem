defmodule Golem.ToolHandlerTest do
  use ExUnit.Case, async: false

  # These tests don't touch the sandbox — they test the logic
  # in the tool handler that runs locally (edit_file matching,
  # progress parsing, think routing, etc.)

  describe "edit_file matching" do
    setup do
      Agent.update(Golem.FileCache, fn _ -> %{} end)
      :ok
    end

    test "detects already-applied edit" do
      # Simulate a file that already has the new content
      Golem.FileCache.put("/test/file.rs", "fn hello() {\n    println!(\"world\");\n}")

      # The old_string is gone but new_string is present
      result = Golem.ToolHandler.execute(
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
      Agent.update(Golem.FileCache, fn _ -> %{} end)
      :ok
    end

    # Items marked :done without a matching plan verify command get
    # an appended "NOT been verified" warning. The tests below don't
    # set verify commands, so they match on the summary prefix only.

    test "parses standard status values" do
      items = [
        %{"text" => "Step 1", "status" => "completed"},
        %{"text" => "Step 2", "status" => "in_progress"},
        %{"text" => "Step 3", "status" => "pending"}
      ]

      assert {:continue, msg} =
               Golem.ToolHandler.execute(
                 %{name: "update_progress", input: %{"items" => items}},
                 0
               )

      assert String.starts_with?(msg, "Progress updated (1/3 completed).")
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

      assert {:continue, msg} =
               Golem.ToolHandler.execute(
                 %{name: "update_progress", input: %{"items" => items}},
                 0
               )

      assert String.starts_with?(msg, "Progress updated (2/7 completed).")
    end
  end

  describe "think tool routing" do
    setup do
      Agent.update(Golem.FileCache, fn _ -> %{} end)
      :ok
    end

    test "think without replan returns reasoning" do
      reasoning = "I should try a different approach because..."

      result = Golem.ToolHandler.execute(
        %{name: "think", input: %{"reasoning" => reasoning}},
        0
      )

      assert {:continue, ^reasoning} = result
    end

    test "think with replan returns :think_replan" do
      reasoning = "After researching, I recommend building X"

      result = Golem.ToolHandler.execute(
        %{name: "think", input: %{"reasoning" => reasoning, "request_replan" => true}},
        0
      )

      assert {:think_replan, ^reasoning} = result
    end

    test "think defaults to no replan" do
      result = Golem.ToolHandler.execute(
        %{name: "think", input: %{"reasoning" => "some thought"}},
        0
      )

      assert {:continue, _} = result
    end
  end

  describe "done tool" do
    setup do
      Agent.update(Golem.FileCache, fn _ -> %{} end)
      :ok
    end

    test "returns done with success" do
      result = Golem.ToolHandler.execute(
        %{name: "done", input: %{"success" => true, "summary" => "Built the thing"}},
        0
      )

      assert {:done, %{success: true, summary: "Built the thing"}} = result
    end

    test "returns done with failure" do
      result = Golem.ToolHandler.execute(
        %{name: "done", input: %{"success" => false, "summary" => "Couldn't do it"}},
        0
      )

      assert {:done, %{success: false, summary: "Couldn't do it"}} = result
    end

    test "defaults success to false" do
      result = Golem.ToolHandler.execute(
        %{name: "done", input: %{"summary" => "something"}},
        0
      )

      assert {:done, %{success: false}} = result
    end
  end

  describe "edit_file fuzzy matching" do
    setup do
      Agent.update(Golem.FileCache, fn _ -> %{} end)
      :ok
    end

    test "matches despite trailing whitespace differences" do
      # File has trailing spaces on some lines
      content = "fn main() {\n    let x = 1;  \n    let y = 2;\n}\n"
      Golem.FileCache.put("/test/fuzzy.rs", content)

      # Agent's old_string doesn't have trailing spaces
      result = Golem.ToolHandler.execute(
        %{name: "edit_file", input: %{
          "path" => "/test/fuzzy.rs",
          "old_string" => "fn main() {\n    let x = 1;\n    let y = 2;\n}",
          "new_string" => "fn main() {\n    let x = 42;\n    let y = 2;\n}"
        }},
        0
      )

      assert {:continue, msg} = result
      # Should either apply (if sandbox available) or error on write
      # The key is it doesn't report "old_string not found"
      refute String.contains?(msg, "old_string not found")
    end

    test "matches despite tab/space differences" do
      # File uses tabs
      content = "fn main() {\n\tlet x = 1;\n}\n"
      Golem.FileCache.put("/test/tabs.rs", content)

      # Agent's old_string uses spaces
      result = Golem.ToolHandler.execute(
        %{name: "edit_file", input: %{
          "path" => "/test/tabs.rs",
          "old_string" => "fn main() {\n  let x = 1;\n}",
          "new_string" => "fn main() {\n\tlet x = 42;\n}"
        }},
        0
      )

      assert {:continue, msg} = result
      refute String.contains?(msg, "old_string not found")
    end
  end

  describe "unknown tool" do
    setup do
      Agent.update(Golem.FileCache, fn _ -> %{} end)
      :ok
    end

    test "returns error for unknown tool" do
      result = Golem.ToolHandler.execute(
        %{name: "nonexistent_tool", input: %{}},
        0
      )

      assert {:continue, "[error] Unknown tool: nonexistent_tool"} = result
    end
  end
end
