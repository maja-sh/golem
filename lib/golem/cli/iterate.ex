defmodule Golem.CLI.Iterate do
  @moduledoc """
  Address reviewer feedback on a pull request the bot opened.

  Usage:

      golem iterate PROJ-456                # by ticket key
      golem iterate your-workspace/api/42          # by workspace/repo/id
      golem iterate https://bitbucket.org/your-workspace/api/pull-requests/42

      golem iterate                        # list open bot PRs with
                                           # unresolved comments

      golem iterate PROJ-456 --budget 20    # raise the cost ceiling

  Pipeline:

    1. Resolve the input to a Bitbucket PR.
    2. Fetch unresolved reviewer comments + tasks.
    3. Worktree-check out the PR's existing branch.
    4. Run the agent with the feedback as the goal.
    5. Push commits back to the same branch.
    6. Reply on each addressed thread with the head SHA.

  Threads are NOT auto-resolved — the human reviewer keeps that authority.
  """

  def run(argv) do
    {opts, rest, _} =
      OptionParser.parse(argv,
        strict: [budget: :float, max_steps: :integer, debug: :boolean],
        aliases: [b: :budget, s: :max_steps]
      )

    Application.ensure_all_started(:golem)

    if opts[:budget], do: Application.put_env(:golem, :max_cost, opts[:budget])

    case rest do
      [] -> show_actionable()
      [arg | _] -> if opts[:debug], do: debug(arg), else: review(arg, opts)
    end
  end

  defp debug(arg) do
    with parsed when not is_tuple(parsed) or elem(parsed, 0) != :error <-
           Golem.Iterate.parse_arg(arg),
         {:ok, config} <- Golem.ProjectSetup.load_config_with_jira(),
         {:ok, pr} <- Golem.Iterate.resolve(parsed, config),
         {:ok, threads} <- Golem.Iterate.diagnose(pr) do
      IO.puts("\nPR: #{pr.workspace}/#{pr.repo}/#{pr.id} — #{pr.url}")
      IO.puts("Bot identity: #{System.get_env("GIT_USER") || "Golem Bot"}\n")
      IO.puts("#{length(threads)} top-level thread(s):\n")

      Enum.each(threads, fn t ->
        marker = if t.actionable, do: "✓", else: "✗"
        loc = if t.top.path, do: " #{t.top.path}:#{t.top.line}", else: ""
        resolved_part = if t.top.resolved, do: " [resolved]", else: ""

        IO.puts("#{marker} ##{t.top.id} by #{t.top.author}#{loc}#{resolved_part} — #{t.reason}")

        IO.puts("    top: #{preview(t.top.body)}")
        IO.puts("    descendants: #{length(t.descendants)}")

        Enum.each(t.descendants, fn d ->
          IO.puts("      ##{d.id} by #{d.author} (parent ##{d.parent_id}, #{d.created})")
          IO.puts("        #{preview(d.body)}")
        end)

        if t.descendants != [] do
          IO.puts("    latest: ##{t.latest.id} by #{t.latest.author} (#{t.latest.created})")
        end

        IO.puts("")
      end)
    else
      {:error, reason} ->
        IO.puts(:stderr, "✗ #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp preview(body) do
    body
    |> String.replace("\n", " ")
    |> String.slice(0, 120)
  end

  defp review(arg, opts) do
    case Golem.Iterate.parse_arg(arg) do
      {:error, :unrecognized} ->
        IO.puts(:stderr, """
        Unrecognized argument: #{inspect(arg)}

        Expected one of:
          PROJ-456                 # ticket key
          your-workspace/api/42           # bitbucket workspace/repo/id
          https://bitbucket.org/your-workspace/api/pull-requests/42
        """)

        exit({:shutdown, 1})

      parsed ->
        with {:ok, config} <- Golem.ProjectSetup.load_config_with_jira(),
             {:ok, pr} <- Golem.Iterate.resolve(parsed, config) do
          runner_opts = if opts[:max_steps], do: [max_steps: opts[:max_steps]], else: []
          Golem.Iterate.run(pr, runner_opts)
        else
          {:error, reason} ->
            IO.puts(:stderr, "\n✗ #{inspect(reason)}")
            exit({:shutdown, 1})
        end
    end
  end

  defp show_actionable do
    case Golem.ProjectSetup.load_config_with_jira() do
      {:ok, config} ->
        summary = Golem.Iterate.actionable_summary(config)

        if summary == [] do
          IO.puts("No open bot PRs found.")
        else
          IO.puts("Usage: golem iterate <ticket-key | pr-path | pr-url>\n")
          IO.puts("Open PRs from this bot:\n")

          for entry <- summary do
            pr = entry.pr
            ticket_part = ticket_label(pr.source_branch)
            count = entry.unresolved
            tasks = entry.tasks

            base =
              cond do
                count == 0 -> "no unresolved items"
                count == 1 -> "1 unresolved item"
                true -> "#{count} unresolved items"
              end

            unresolved_part =
              if tasks > 0,
                do: "#{base} (#{tasks} task#{if tasks == 1, do: "", else: "s"})",
                else: base

            IO.puts("  #{ticket_part}  #{pr.workspace}/#{pr.repo}/#{pr.id}  · #{unresolved_part}")
            IO.puts("      #{pr.url}")
          end
        end

      {:error, reason} ->
        IO.puts(:stderr, "✗ #{inspect(reason)}")
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
