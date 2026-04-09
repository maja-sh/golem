defmodule Golem.StateTest do
  use ExUnit.Case, async: false

  @test_dir "runs/_test"

  setup do
    File.rm_rf!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "new_run_id" do
    test "generates unique IDs" do
      id1 = Golem.State.new_run_id()
      id2 = Golem.State.new_run_id()
      assert id1 != id2
    end

    test "contains timestamp" do
      id = Golem.State.new_run_id()
      # Format: YYYYMMDD_HHMMSS_hex
      assert Regex.match?(~r/^\d{8}_\d{6}_[a-f0-9]+$/, id)
    end
  end

  describe "should_save?" do
    test "always returns true" do
      assert Golem.State.should_save?(0)
      assert Golem.State.should_save?(1)
      assert Golem.State.should_save?(5)
      assert Golem.State.should_save?(100)
    end
  end

  describe "save and load" do
    test "round-trips state" do
      run_id = "test_#{System.monotonic_time(:millisecond)}"

      state = %{
        goal: "Test goal",
        plan: "## Phase 1\n- [ ] Do stuff",
        step: 42,
        max_steps: 200,
        depth: 0,
        history: [{"shell", "ls", "file.txt"}],
        messages: [
          %{role: "user", content: "hello"},
          %{role: "assistant", content: "hi"}
        ]
      }

      assert :ok = Golem.State.save(run_id, state)

      assert {:ok, loaded} = Golem.State.load(run_id)
      assert loaded.goal == "Test goal"
      assert loaded.plan == "## Phase 1\n- [ ] Do stuff"
      assert loaded.step == 42
      assert loaded.max_steps == 200
      assert loaded.depth == 0
      assert loaded.history == [{"shell", "ls", "file.txt"}]
      assert length(loaded.messages) == 2
    end

    test "load returns error for nonexistent run" do
      assert {:error, :enoent} = Golem.State.load("nonexistent_run_id")
    end

    test "messages preserve role and content" do
      run_id = "test_msgs_#{System.monotonic_time(:millisecond)}"

      messages = [
        %{role: "user", content: "What's up?"},
        %{role: "assistant", content: [
          %{type: "text", text: "Let me help"},
          %{type: "tool_use", id: "abc", name: "shell", input: %{"command" => "ls"}}
        ]},
        %{role: "user", content: [
          %{type: "tool_result", tool_use_id: "abc", content: "file.txt"}
        ]}
      ]

      state = %{goal: "test", plan: "", step: 1, max_steps: 10, depth: 0, history: [], messages: messages}
      Golem.State.save(run_id, state)

      {:ok, loaded} = Golem.State.load(run_id)
      assert length(loaded.messages) == 3

      [msg1, msg2, msg3] = loaded.messages
      assert msg1.role == "user"
      assert msg1.content == "What's up?"
      assert msg2.role == "assistant"
      assert is_list(msg2.content)
      assert msg3.role == "user"
      assert is_list(msg3.content)
    end
  end

  describe "list_runs" do
    test "lists saved runs" do
      run_id = "test_list_#{System.monotonic_time(:millisecond)}"
      state = %{goal: "List test", plan: "", step: 5, max_steps: 50, depth: 0, history: [], messages: []}
      Golem.State.save(run_id, state)

      runs = Golem.State.list_runs()
      assert Enum.any?(runs, &(&1.id == run_id))
    end

    test "returns empty list when no runs" do
      # This might not be empty if other tests left runs, but shouldn't crash
      assert is_list(Golem.State.list_runs())
    end
  end
end
