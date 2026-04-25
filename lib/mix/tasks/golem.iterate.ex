defmodule Mix.Tasks.Golem.Iterate do
  @moduledoc """
  Address reviewer feedback on a pull request the bot opened.

  ## Usage

      mix golem.iterate SA-2100                # by ticket key
      mix golem.iterate hrdl/api/3480          # by workspace/repo/id
      mix golem.iterate https://bitbucket.org/hrdl/api/pull-requests/3480

      mix golem.iterate                        # list open bot PRs with
                                              # unresolved comments

      mix golem.iterate SA-2100 --budget 20    # raise the cost ceiling

  Pipeline:

    1. Resolve the input to a Bitbucket PR.
    2. Fetch unresolved reviewer comments (filtered to non-bot authors).
    3. Worktree-check out the PR's existing branch.
    4. Run the agent with the comments as the goal.
    5. Push commits back to the same branch.
    6. Reply on each addressed thread with the head SHA.

  Threads are NOT auto-resolved — the human reviewer keeps that authority.
  """

  use Mix.Task

  @shortdoc "Address reviewer feedback on a bot-opened PR"

  @impl true
  def run(args) do
    {opts, rest, _} =
      OptionParser.parse(args,
        strict: [budget: :float, max_steps: :integer],
        aliases: [b: :budget, s: :max_steps]
      )

    Mix.Task.run("app.start")

    if opts[:budget], do: Application.put_env(:golem, :max_cost, opts[:budget])

    case rest do
      [] -> show_actionable()
      [arg | _] -> review(arg, opts)
    end
  end

  defp review(arg, opts) do
    case Golem.Iterate.parse_arg(arg) do
      {:error, :unrecognized} ->
        Mix.shell().error("""
        Unrecognized argument: #{inspect(arg)}

        Expected one of:
          SA-2100                 # ticket key
          hrdl/api/3480           # bitbucket workspace/repo/id
          https://bitbucket.org/hrdl/api/pull-requests/3480
        """)

        exit({:shutdown, 1})

      parsed ->
        with {:ok, config} <- Golem.ProjectSetup.load_config_with_jira(),
             {:ok, pr} <- Golem.Iterate.resolve(parsed, config) do
          runner_opts =
            (if opts[:max_steps], do: [max_steps: opts[:max_steps]], else: [])

          Golem.Iterate.run(pr, runner_opts)
        else
          {:error, reason} ->
            Mix.shell().error("\n✗ #{inspect(reason)}")
            exit({:shutdown, 1})
        end
    end
  end

  defp show_actionable do
    case Golem.ProjectSetup.load_config_with_jira() do
      {:ok, config} ->
        summary = Golem.Iterate.actionable_summary(config)

        if summary == [] do
          Mix.shell().info("No open bot PRs found.")
        else
          Mix.shell().info("Usage: mix golem.iterate <ticket-key | pr-path | pr-url>\n")
          Mix.shell().info("Open PRs from this bot:\n")

          for entry <- summary do
            pr = entry.pr
            ticket_part = ticket_label(pr.source_branch)
            count = entry.unresolved
            unresolved_part =
              cond do
                count == 0 -> "no unresolved threads"
                count == 1 -> "1 unresolved thread"
                true -> "#{count} unresolved threads"
              end

            Mix.shell().info(
              "  #{ticket_part}  #{pr.workspace}/#{pr.repo}/#{pr.id}  · #{unresolved_part}"
            )
            Mix.shell().info("      #{pr.url}")
          end
        end

      {:error, reason} ->
        Mix.shell().error("✗ #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp ticket_label(branch) do
    case Regex.run(~r{^golem/([A-Z]+-\d+)-}, branch) do
      [_, key] -> String.pad_trailing(key, 10)
      _ -> String.pad_trailing("(no key)", 10)
    end
  end
end
