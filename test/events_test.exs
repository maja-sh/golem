defmodule Golem.EventsTest do
  # async: false — Golem.Events uses Process dict + real filesystem
  use ExUnit.Case, async: false

  alias Golem.Events

  @tmp_root "test/tmp_events"

  setup do
    # Each test runs in its own subdir under @tmp_root, and we chdir so
    # the "runs/..." path Events writes to lands inside the temp tree.
    test_dir = Path.join(@tmp_root, "#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(test_dir)
    original_cwd = File.cwd!()
    File.cd!(test_dir)

    on_exit(fn ->
      File.cd!(original_cwd)
      File.rm_rf!(@tmp_root)
    end)

    {:ok, run_id: "run_#{:erlang.unique_integer([:positive])}"}
  end

  describe "set_run/1 + current_run/0 + clear_run/0" do
    test "round-trip", %{run_id: id} do
      assert Events.current_run() == nil
      Events.set_run(id)
      assert Events.current_run() == id
      Events.clear_run()
      assert Events.current_run() == nil
    end
  end

  describe "emit/2 without an active run" do
    test "silently no-ops" do
      # No set_run called → should not create any file.
      assert Events.emit(:tool_call, %{name: "shell"}) == :ok
      refute File.exists?("runs")
    end
  end

  describe "emit/2 — event file format" do
    setup %{run_id: id} do
      Events.set_run(id)
      on_exit(fn -> Events.clear_run() end)
      :ok
    end

    test "writes a JSON line with ts, type, payload", %{run_id: id} do
      Events.emit(:tool_call, %{name: "shell", input: %{"command" => "ls"}})

      [entry] = Events.read(id)
      assert entry["type"] == "tool_call"
      assert is_binary(entry["ts"])
      assert entry["ts"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
      assert entry["payload"]["name"] == "shell"
      assert entry["payload"]["input"]["command"] == "ls"
    end

    test "hoists :step and :depth to top-level fields", %{run_id: id} do
      Events.emit(:step, %{step: 12, depth: 0, foo: "bar"})

      [entry] = Events.read(id)
      assert entry["step"] == 12
      assert entry["depth"] == 0
      assert entry["payload"]["foo"] == "bar"
      # step and depth should NOT also be in payload
      refute Map.has_key?(entry["payload"], "step")
      refute Map.has_key?(entry["payload"], "depth")
    end

    test "omits step/depth when not provided", %{run_id: id} do
      Events.emit(:run_start, %{goal: "hi"})

      [entry] = Events.read(id)
      refute Map.has_key?(entry, "step")
      refute Map.has_key?(entry, "depth")
    end

    test "appends multiple events in order", %{run_id: id} do
      Events.emit(:run_start, %{goal: "test"})
      Events.emit(:step, %{step: 1})
      Events.emit(:tool_call, %{name: "shell", step: 1})

      entries = Events.read(id)
      assert length(entries) == 3
      assert [%{"type" => "run_start"}, %{"type" => "step"}, %{"type" => "tool_call"}] = entries
    end

    test "sanitizes non-JSON-encodable values (pids, tuples)", %{run_id: id} do
      Events.emit(:custom, %{pid: self(), pair: {1, 2}})

      [entry] = Events.read(id)
      # pid becomes an inspect-stringified form; tuple becomes a list.
      assert is_binary(entry["payload"]["pid"])
      assert entry["payload"]["pair"] == [1, 2]
    end

    test "nested structures are sanitized too", %{run_id: id} do
      Events.emit(:custom, %{outer: %{inner: {1, 2, 3}}})

      [entry] = Events.read(id)
      assert entry["payload"]["outer"]["inner"] == [1, 2, 3]
    end
  end

  describe "emit_to/3" do
    test "writes to a specific run regardless of process binding" do
      id_a = "run_a_#{:erlang.unique_integer([:positive])}"
      id_b = "run_b_#{:erlang.unique_integer([:positive])}"

      Events.set_run(id_a)
      Events.emit_to(id_b, :step, %{step: 1})
      Events.emit(:step, %{step: 2})
      Events.clear_run()

      assert [%{"step" => 1}] = Events.read(id_b)
      # id_a gets the :step 2 event (via process-bound run)
      assert [%{"step" => 2}] = Events.read(id_a)
    end
  end

  describe "read/2" do
    test "returns [] for missing file" do
      assert Events.read("nonexistent_run") == []
    end

    test "tail option returns last N entries", %{run_id: id} do
      Events.set_run(id)
      for i <- 1..10, do: Events.emit(:step, %{step: i})
      Events.clear_run()

      last_three = Events.read(id, tail: 3)
      assert length(last_three) == 3
      # `step` is hoisted to top-level by the emitter, not left inside payload
      assert Enum.map(last_three, & &1["step"]) == [8, 9, 10]
    end
  end
end
