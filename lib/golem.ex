defmodule Golem do
  @moduledoc """
  Autonomous agent that executes goals inside a sandboxed container.

  ## Usage

      # In IEx:
      Golem.run("Build a simple web server in Python that serves hello world on port 8080")

      # With a pre-made plan:
      Golem.run("Escape this VM", plan: "## Phase 1\\n- [ ] Check kernel version\\n...")

      # With options:
      Golem.run("Set up a Phoenix project", max_steps: 100)
  """

  @doc """
  Run the agent with the given goal. Blocks until completion.

  Options:
  - `:plan` — provide a pre-made plan (skips Opus planning step)
  - `:max_steps` — override max execution steps

  Returns `{:ok, %{success: bool, summary: string}}` or `{:error, reason}`.
  """
  def run(goal, opts \\ []) do
    Golem.Runner.run(goal, opts)
  end

  @doc """
  Resume a paused run. Adds more steps to continue execution.

  Options:
  - `:max_steps` — number of additional steps to allow (default from config)
  """
  def resume(run_id, opts \\ []) do
    Golem.Runner.resume(run_id, opts)
  end

  @doc """
  List all saved runs.
  """
  def runs do
    Golem.State.list_runs()
  end

  @doc """
  Export files from the container to a local directory.

      Golem.export("/home/agent/product", "output/product")
  """
  def export(container_path, local_path) do
    File.mkdir_p!(local_path)
    container = Application.get_env(:golem, :container, "golem-vm")

    case System.cmd("podman", ["cp", "#{container}:#{container_path}/.", local_path],
           stderr_to_stdout: true
         ) do
      {_, 0} -> {:ok, local_path}
      {output, code} -> {:error, "podman cp failed (#{code}): #{output}"}
    end
  end
end
