defmodule Penbot.ToolsTest do
  use ExUnit.Case, async: true

  describe "for_depth" do
    test "depth 0 includes sub_agent" do
      tools = Penbot.Tools.for_depth(0)
      names = Enum.map(tools, & &1.name)
      assert "sub_agent" in names
    end

    test "max depth excludes sub_agent" do
      tools = Penbot.Tools.for_depth(3)
      names = Enum.map(tools, & &1.name)
      refute "sub_agent" in names
    end

    test "always includes core tools" do
      for depth <- 0..5 do
        tools = Penbot.Tools.for_depth(depth)
        names = Enum.map(tools, & &1.name)

        assert "shell" in names
        assert "write_file" in names
        assert "read_file" in names
        assert "edit_file" in names
        assert "think" in names
        assert "done" in names
        assert "glob" in names
        assert "grep" in names
        assert "web_search" in names
      end
    end

    test "all tools have required fields" do
      for tool <- Penbot.Tools.all() do
        assert is_binary(tool.name), "tool missing name"
        assert is_binary(tool.description), "#{tool.name} missing description"
        assert is_map(tool.input_schema), "#{tool.name} missing input_schema"
        assert tool.input_schema.type == "object", "#{tool.name} schema not object type"
      end
    end

    test "ask_user included only when discord token set" do
      # This depends on env var — just test the function doesn't crash
      tools = Penbot.Tools.for_depth(0)
      names = Enum.map(tools, & &1.name)

      if System.get_env("DISCORD_TOKEN") do
        assert "ask_user" in names
      else
        refute "ask_user" in names
      end
    end
  end
end
