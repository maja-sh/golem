defmodule Golem.Runner.ReminderTest do
  use ExUnit.Case, async: true

  alias Golem.Runner.Reminder

  describe "build/1" do
    test "wraps in <system-reminder> tags" do
      out = Reminder.build(step: 10, max_steps: 200, cost: 1.23, budget: 10.0)
      assert out =~ "<system-reminder>"
      assert out =~ "</system-reminder>"
    end

    test "step/budget line shows percentage" do
      out = Reminder.build(step: 50, max_steps: 200, cost: 2.5, budget: 10.0)
      assert out =~ "Step 50/200"
      assert out =~ "$2.50"
      assert out =~ "$10.00"
      assert out =~ "(25% budget used)"
    end

    test "zero budget shows 0%, not a crash" do
      out = Reminder.build(step: 3, max_steps: 200, cost: 0.5, budget: 0.0)
      assert out =~ "(0% budget used)"
    end

    test "omits progress line when progress is empty" do
      out = Reminder.build(step: 3, max_steps: 200)
      refute out =~ "- Progress:"
    end

    test "includes progress summary with active item" do
      progress = [
        %{text: "step one", status: :completed},
        %{text: "step two", status: :completed},
        %{text: "step three", status: :in_progress},
        %{text: "step four", status: :pending}
      ]

      out = Reminder.build(step: 5, max_steps: 200, progress: progress)
      assert out =~ "- Progress: 2/4 done"
      assert out =~ ~s(active: "step three")
    end

    test "omits recent commands when history is empty" do
      out = Reminder.build(step: 3, max_steps: 200)
      refute out =~ "Recent tool calls"
    end

    test "includes recent commands with status" do
      history = [
        {"shell", "ls /home", "file1\nfile2"},
        {"shell", "npm run build", "[exit code 137]\npartial"},
        {"grep", "has_injury", "match1\nmatch2"}
      ]

      out = Reminder.build(step: 10, max_steps: 200, history: history)
      assert out =~ "- Recent tool calls:"
      assert out =~ "[shell] ls /home"
      assert out =~ "[shell] npm run build → exit 137"
      assert out =~ "[grep] has_injury"
    end

    test "respects recent_n" do
      history =
        for i <- 1..20, do: {"shell", "cmd#{i}", "out"}

      out = Reminder.build(step: 20, max_steps: 200, history: history, recent_n: 3)
      assert out =~ "cmd18"
      assert out =~ "cmd19"
      assert out =~ "cmd20"
      refute out =~ "cmd17"
    end
  end

  describe "format_progress_line/1" do
    test "empty" do
      assert Reminder.format_progress_line([]) == ""
    end

    test "counts both :done and :completed as done" do
      items = [
        %{text: "a", status: :done},
        %{text: "b", status: :completed},
        %{text: "c", status: :pending}
      ]

      assert Reminder.format_progress_line(items) =~ "2/3 done"
    end

    test "no active item skips the active suffix" do
      items = [%{text: "a", status: :pending}]
      line = Reminder.format_progress_line(items)
      assert line =~ "0/1 done"
      refute line =~ "active:"
    end

    test "truncates long active text" do
      items = [%{text: String.duplicate("x", 100), status: :in_progress}]
      line = Reminder.format_progress_line(items)
      assert line =~ "..."
    end
  end

  describe "format_recent_commands/2" do
    test "empty history returns empty string" do
      assert Reminder.format_recent_commands([], 5) == ""
    end

    test "truncates long input strings" do
      cmd = String.duplicate("a", 200)
      out = Reminder.format_recent_commands([{"shell", cmd, "ok"}], 5)
      assert out =~ "..."
    end

    test "takes only the last N entries" do
      history = [
        {"shell", "first", "out"},
        {"shell", "second", "out"},
        {"shell", "third", "out"}
      ]

      out = Reminder.format_recent_commands(history, 2)
      refute out =~ "first"
      assert out =~ "second"
      assert out =~ "third"
    end
  end

  describe "short_status/1" do
    test "shell exit codes" do
      assert Reminder.short_status("[exit code 137]\npartial") == " → exit 137"
      assert Reminder.short_status("[exit code 0]\n") == " → exit 0"
    end

    test "malformed exit line is failed" do
      assert Reminder.short_status("[exit code X]\n") == " → failed"
    end

    test "command stalled" do
      assert Reminder.short_status("[command stalled — no output for 120s]") == " → stalled"
    end

    test "command timed out" do
      assert Reminder.short_status("[command timed out]\npartial") == " → timed out"
    end

    test "generic error" do
      assert Reminder.short_status("[error] file not found") == " → error"
    end

    test "plain success returns empty" do
      assert Reminder.short_status("file1\nfile2\n") == ""
    end

    test "non-binary result returns empty" do
      assert Reminder.short_status(nil) == ""
      assert Reminder.short_status(:some_atom) == ""
    end
  end
end
