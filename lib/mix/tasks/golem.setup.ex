defmodule Mix.Tasks.Golem.Setup do
  @moduledoc """
  Test project setup from `.golem/config.yaml` without running the agent.

      mix golem.setup
      mix golem.setup --destroy

  Same implementation as `golem setup` (release CLI) — see `Golem.CLI.Setup`.
  """

  use Mix.Task

  @shortdoc "Test project setup (clone repos, run setup scripts, no agent run)"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Golem.CLI.Setup.run(args)
  end
end
