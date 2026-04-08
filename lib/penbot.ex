defmodule Penbot do
  @moduledoc """
  Autonomous agent that executes goals inside a sandboxed container.

  ## Usage

      # In IEx:
      Penbot.run("Build a simple web server in Python that serves hello world on port 8080")

      # With a pre-made plan:
      Penbot.run("Escape this VM", plan: "## Phase 1\\n- [ ] Check kernel version\\n...")

      # With options:
      Penbot.run("Set up a Phoenix project", max_steps: 100)
  """

  @doc """
  Run the agent with the given goal. Blocks until completion.

  Options:
  - `:plan` — provide a pre-made plan (skips Opus planning step)
  - `:max_steps` — override max execution steps

  Returns `{:ok, %{success: bool, summary: string}}` or `{:error, reason}`.
  """
  def run(goal, opts \\ []) do
    Penbot.Runner.run(goal, opts)
  end
end
