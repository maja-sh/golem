defmodule Golem.Runner.TriggersTest do
  use ExUnit.Case, async: true

  alias Golem.Runner.Triggers

  # Test helpers — build history tuples / executed tuples in the same
  # shape the runner produces.

  defp hist(tool, input, result \\ "ok"), do: {tool, input, result}

  defp exec(name, input, result \\ {:text, "ok"}) do
    {%{name: name, input: input}, result}
  end

  describe "classify_stuck/2 — edit loop" do
    test "fires at 4+ edits on the same file" do
      history =
        List.duplicate(hist("edit_file", "/foo/bar.ex"), 3)

      executed = [exec("edit_file", %{"path" => "/foo/bar.ex"})]

      assert {:edit_loop, [entry]} = Triggers.classify_stuck(history, executed)
      assert entry =~ "bar.ex"
      assert entry =~ "(4 edits)"
    end

    test "does not fire at 3 edits" do
      history = List.duplicate(hist("edit_file", "/foo/bar.ex"), 2)
      executed = [exec("edit_file", %{"path" => "/foo/bar.ex"})]

      assert Triggers.classify_stuck(history, executed) == :ok
    end

    test "counts write_file toward edit loop" do
      history =
        [
          hist("write_file", "/foo/bar.ex"),
          hist("edit_file", "/foo/bar.ex"),
          hist("edit_file", "/foo/bar.ex")
        ]

      executed = [exec("write_file", %{"path" => "/foo/bar.ex"})]

      assert {:edit_loop, _} = Triggers.classify_stuck(history, executed)
    end

    test "different files are not a loop" do
      history = [
        hist("edit_file", "/a.ex"),
        hist("edit_file", "/b.ex"),
        hist("edit_file", "/c.ex")
      ]

      executed = [exec("edit_file", %{"path" => "/d.ex"})]
      assert Triggers.classify_stuck(history, executed) == :ok
    end
  end

  describe "classify_stuck/2 — shell loop" do
    test "fires at 3 repeats of the same shell command" do
      history = [
        hist("shell", "npm run build"),
        hist("shell", "npm run build")
      ]

      executed = [exec("shell", %{"command" => "npm run build"})]

      assert {:shell_loop, [entry]} = Triggers.classify_stuck(history, executed)
      assert entry =~ "npm run build"
      assert entry =~ "(3x)"
    end

    test "counts only last 10 shell entries" do
      # History has 15 shells of cmd_a; last 10 dominate
      history =
        List.duplicate(hist("shell", "cmd_a"), 5) ++
          List.duplicate(hist("shell", "cmd_b"), 10)

      executed = [exec("shell", %{"command" => "cmd_b"})]
      result = Triggers.classify_stuck(history, executed)

      assert {:shell_loop, entries} = result
      # Only cmd_b should trip; cmd_a outside the 10-window
      assert Enum.any?(entries, &String.contains?(&1, "cmd_b"))
    end
  end

  describe "classify_stuck/2 — repeat loop" do
    test "catches identical non-shell tool calls" do
      history = [
        hist("grep", "foo"),
        hist("grep", "foo")
      ]

      # Use same input so phash2 matches
      executed = [exec("grep", "foo")]

      assert {:repeat_loop, count} = Triggers.classify_stuck(history, executed)
      assert count >= 1
    end

    test "no loop returns :ok" do
      assert Triggers.classify_stuck([], []) == :ok
    end
  end

  describe "classify_think_loop/2" do
    test "not a loop when other tools are also executed" do
      assert Triggers.classify_think_loop(["think", "shell"], 2) == {:ok, 0}
    end

    test "increments counter when only think was called" do
      assert Triggers.classify_think_loop(["think"], 1) == {:ok, 2}
    end

    test "resets counter on action" do
      assert Triggers.classify_think_loop(["shell"], 5) == {:ok, 0}
    end

    test "fires at 3 consecutive think-only turns" do
      assert Triggers.classify_think_loop(["think"], 2) == {:think_loop, 3}
    end

    test "fires above threshold too" do
      assert {:think_loop, 4} = Triggers.classify_think_loop(["think"], 3)
    end
  end

  describe "drift_signals/1" do
    test "empty signals when everything looks normal" do
      history =
        for i <- 1..10 do
          hist("shell", "cmd#{i}", "output ok")
        end

      signals =
        Triggers.drift_signals(
          step: 10,
          history: history,
          last_progress_step: 9
        )

      assert signals == []
    end

    test "flags stale progress" do
      signals = Triggers.drift_signals(step: 20, history: [], last_progress_step: 0)
      assert :stale_progress in signals
    end

    test "flags narrow tools when last 20 use ≤ 2 unique" do
      history =
        for i <- 1..25 do
          tool = if rem(i, 2) == 0, do: "shell", else: "grep"
          hist(tool, "x", "out")
        end

      signals = Triggers.drift_signals(step: 30, history: history, last_progress_step: 29)
      assert :narrow_tools in signals
    end

    test "does not flag narrow tools with fewer than 20 history entries" do
      history = List.duplicate(hist("shell", "x", "out"), 5)
      signals = Triggers.drift_signals(step: 10, history: history, last_progress_step: 9)
      refute :narrow_tools in signals
    end

    test "flags high error rate" do
      history =
        for i <- 1..15 do
          result = if rem(i, 2) == 0, do: "[error] failed", else: "ok"
          hist("shell", "cmd", result)
        end

      signals = Triggers.drift_signals(step: 20, history: history, last_progress_step: 19)
      assert :high_error_rate in signals
    end

    test "error rate only fires with enough sample size" do
      history = [hist("shell", "cmd", "[error] x"), hist("shell", "cmd", "[error] x")]
      signals = Triggers.drift_signals(step: 5, history: history, last_progress_step: 4)
      refute :high_error_rate in signals
    end

    test "multiple signals combine" do
      history =
        for _ <- 1..25 do
          hist("shell", "cmd", "[error] boom")
        end

      signals =
        Triggers.drift_signals(step: 100, history: history, last_progress_step: 0)

      assert :stale_progress in signals
      assert :narrow_tools in signals
      assert :high_error_rate in signals
    end
  end

  describe "check_staleness/3" do
    test "returns :ok when progress is recent" do
      assert Triggers.check_staleness(10, 9, 0) == :ok
    end

    test "nudges when gap >= threshold and nudge cooldown passed" do
      assert {:nudge, 25} = Triggers.check_staleness(25, 0, 0)
    end

    test "does not re-nudge within the cooldown window" do
      # Just nudged at step 25; don't nudge again at step 30
      assert Triggers.check_staleness(30, 5, 25) == :ok
    end

    test "nudges again after cooldown" do
      # Nudged at 25, cooldown is 20 — next nudge allowed at 45+
      assert {:nudge, _} = Triggers.check_staleness(45, 5, 25)
    end
  end

  describe "oversized_writes/1" do
    test "empty when no writes" do
      assert Triggers.oversized_writes([]) == []
    end

    test "returns oversized writes with their line count" do
      content = Enum.map_join(1..400, "\n", &"line #{&1}")

      executed = [
        exec("write_file", %{"path" => "/foo.ex", "content" => content}),
        exec("write_file", %{"path" => "/small.ex", "content" => "a\nb"})
      ]

      result = Triggers.oversized_writes(executed)
      assert [{"/foo.ex", lines}] = result
      assert lines >= 300
    end

    test "ignores non-write tools" do
      executed = [
        exec("shell", %{"command" => String.duplicate("x\n", 500)})
      ]

      assert Triggers.oversized_writes(executed) == []
    end
  end

  describe "thresholds/0" do
    test "exposes values" do
      t = Triggers.thresholds()
      assert t.stuck_edit == 4
      assert t.stuck_shell == 3
      assert t.max_thinks == 3
      assert t.file_size == 300
    end
  end
end
