# Simulates a 3-item checklist with a spinner that ticks 10 times.
# The first three lines never change; only the spinner line does.

frame_for = fn frame, secs ->
  [
    "[\e[32m✓\e[0m] Bootstrap",
    "[\e[33m→\e[0m] Build",
    "[ ] Ship",
    "",
    " \e[36m#{frame}\e[0m Working — #{secs}s"
  ]
end

frames = ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

tick_steps =
  frames
  |> Enum.with_index(1)
  |> Enum.flat_map(fn {frame, n} ->
    [{:sleep, 100}, {:pin, frame_for.(frame, n)}]
  end)

[{:pin, frame_for.("⠋", 0)}, {:mark, :after_initial}] ++ tick_steps
