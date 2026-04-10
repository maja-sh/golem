defmodule Mix.Tasks.Golem.Daemon do
  @moduledoc """
  Start Golem as a long-running daemon controlled via Discord.

  ## Usage

      mix golem.daemon

  ## Discord Commands

      run smoke_maze              — run a scenario
      run "Build a web server"    — run with a custom goal
      fix chainpost: tests fail   — fix an existing project
      resume                      — resume the latest paused run
      resume <run_id>             — resume a specific run
      status                      — show current job info
      stop                        — stop the current job
      runs                        — list saved runs
  """

  use Mix.Task

  @shortdoc "Start Golem daemon (Discord-controlled)"

  @impl true
  def run(_args) do
    # Set daemon mode before app starts
    Application.put_env(:golem, :mode, :daemon)
    Application.put_env(:golem, :output_backend, Golem.Discord.Reporter)

    Mix.Task.run("app.start")

    Mix.shell().info("Golem daemon started. Listening on Discord.")
    Mix.shell().info("Send commands in your Discord channel.")

    # Block forever — the supervision tree keeps running
    Process.sleep(:infinity)
  end
end
