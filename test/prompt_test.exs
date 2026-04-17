defmodule Golem.PromptTest do
  use ExUnit.Case, async: true

  alias Golem.Prompt

  describe "executor_system/2" do
    test "returns single cached block with no errors and no agents_md" do
      [block] = Prompt.executor_system([], nil)
      assert block.type == "text"
      assert block.cache_control == %{type: "ephemeral"}
      assert is_binary(block.text)
      assert String.contains?(block.text, "autonomous agent")
    end

    test "adds a cached agents_md block when agents_md is present" do
      [static, agents] = Prompt.executor_system([], "## Project rules\n\nFollow X.")
      assert static.cache_control == %{type: "ephemeral"}
      assert agents.cache_control == %{type: "ephemeral"}
      assert agents.text =~ "Project Instructions"
      assert agents.text =~ "Follow X"
    end

    test "adds an uncached errors block when errors are present" do
      [static, errors] = Prompt.executor_system(["npm run build exited 137"], nil)
      assert static.cache_control == %{type: "ephemeral"}
      refute Map.has_key?(errors, :cache_control)
      assert errors.text =~ "Lessons learned"
      assert errors.text =~ "npm run build exited 137"
    end

    test "all three blocks present when both agents_md and errors are set" do
      [static, agents, errors] =
        Prompt.executor_system(["err1", "err2"], "project details")

      assert static.cache_control == %{type: "ephemeral"}
      assert agents.cache_control == %{type: "ephemeral"}
      refute Map.has_key?(errors, :cache_control)

      # Errors are numbered
      assert errors.text =~ "1. err1"
      assert errors.text =~ "2. err2"
    end

    test "block order is static → agents → errors" do
      [b1, b2, b3] = Prompt.executor_system(["e"], "md")
      assert b1.text =~ "autonomous agent"
      assert b2.text =~ "Project Instructions"
      assert b3.text =~ "Lessons learned"
    end

    test "empty error list is treated as no errors" do
      result = Prompt.executor_system([], nil)
      assert length(result) == 1
    end
  end
end
