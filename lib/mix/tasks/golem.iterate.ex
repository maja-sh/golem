defmodule Mix.Tasks.Golem.Iterate do
  @moduledoc """
  Address reviewer feedback on a pull request the bot opened.

      mix golem.iterate SA-2100
      mix golem.iterate hrdl/api/3480
      mix golem.iterate https://bitbucket.org/hrdl/api/pull-requests/3480
      mix golem.iterate                        # list open bot PRs

  Same implementation as `golem iterate` (release CLI) — see `Golem.CLI.Iterate`.
  """

  use Mix.Task

  @shortdoc "Address reviewer feedback on a bot-opened PR"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Golem.CLI.Iterate.run(args)
  end
end
