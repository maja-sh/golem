defmodule Mix.Tasks.PinnedStatus.Demo do
  @moduledoc """
  Play a `PinnedStatus.Scenario` file against the real terminal so a
  human can eyeball whether redraws look right.

      mix pinned_status.demo test/scenarios/checklist_tick.exs

  Sleeps in the scenario are honored — this is not a test runner; it's
  a visual reproduction.
  """

  use Mix.Task

  @shortdoc "Play a pinned-status scenario against the terminal"

  @impl Mix.Task
  def run([path]) do
    steps = PinnedStatus.Scenario.load(path)
    {:ok, _} = PinnedStatus.start_link()

    try do
      :ok = PinnedStatus.Scenario.play(PinnedStatus, steps, real_time: true)
      # Hold the final frame briefly so the operator can read it.
      Process.sleep(800)
    after
      PinnedStatus.stop()
    end
  end

  def run(_) do
    Mix.shell().error("usage: mix pinned_status.demo <scenario.exs>")
    exit({:shutdown, 1})
  end
end
