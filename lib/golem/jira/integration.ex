defmodule Golem.Jira.Integration do
  @moduledoc """
  Orchestrates the full Jira-driven lifecycle:
  evaluate ticket → setup projects → run agent → push/PR/comment.
  """

  require Logger

  defp output, do: Golem.Output.current()

  @doc """
  Run the full Jira integration pipeline for a ticket key.
  """
  def run(ticket_key, opts \\ []) do
    Logger.info("Jira integration starting for #{ticket_key}")
    output().planning("Fetching ticket #{ticket_key}...")

    skip_eval = Keyword.get(opts, :skip_eval, false)

    with {:ok, config} <- Golem.ProjectSetup.load_config_with_jira(),
         {:ok, ticket} <- Golem.Jira.fetch_ticket(ticket_key, config.jira_base_url),
         :ok <- (output().agent_text("#{ticket.key}: #{ticket.summary}"); :ok),
         {:ok, evaluation} <- evaluate_or_skip(ticket, config, skip_eval) do

      selected_config = filter_config(config, evaluation.selected_projects)
      projects_label = Enum.map_join(selected_config.projects, ", ", & &1.repo)
      Logger.info("Selected projects: #{projects_label}")
      output().planning("Selected projects: #{projects_label}")

      output().planning("Setting up projects...")
      with {:ok, branch, task_config} <- Golem.ProjectSetup.setup_projects(selected_config, ticket.key, ticket.summary) do
        output().agent_text("Branch: #{branch}")

        # Use task_config which has worktree paths instead of main clone paths
        goal = build_goal(ticket, task_config)
        agents_md = build_agents_md(task_config, branch, ticket)

        runner_opts =
          opts
          |> Keyword.put(:agents_md, agents_md)

        Logger.info("Running agent for #{ticket_key}: #{ticket.summary}")
        output().planning("Starting agent...")

        case Golem.run(goal, runner_opts) do
          {:ok, %{success: true} = result} ->
            handle_success(task_config, ticket, branch, result)

          {:ok, %{success: false} = result} ->
            handle_rejection(task_config, ticket, branch, result)

          {:error, :max_steps_reached} = err ->
            comment_on_ticket(task_config, ticket, "Golem run paused — max steps reached. Resume manually.")
            err

          {:error, reason} = err ->
            handle_error(task_config, ticket, reason)
            err
        end
      end
    else
      {:error, :ticket_rejected} = err -> err

      {:error, reason} = err ->
        Logger.error("Jira integration failed: #{inspect(reason)}")
        err
    end
  end

  # --- Evaluation ---

  defp evaluate_or_skip(_ticket, config, true) do
    output().planning("Skipping evaluation (--force)")
    all_repos = Enum.map(config.projects, & &1.repo)
    {:ok, %{selected_projects: all_repos}}
  end

  defp evaluate_or_skip(ticket, config, false) do
    evaluate_and_filter(ticket, config)
  end

  defp evaluate_and_filter(ticket, config) do
    Logger.info("Evaluating ticket #{ticket.key}...")
    output().planning("Evaluating ticket...")

    case Golem.Jira.Evaluator.evaluate(ticket, config) do
      {:ok, %{decision: "reject", reason: reason}} ->
        Logger.info("Ticket #{ticket.key} rejected: #{reason}")
        output().agent_text("Rejected: #{reason}")
        comment = "Golem evaluated this ticket and decided not to proceed.\n\n**Reason:** #{reason}"
        comment_on_ticket(config, ticket, comment)
        {:error, :ticket_rejected}

      {:ok, %{decision: "accept"} = eval} ->
        Logger.info("Ticket #{ticket.key} accepted: #{eval.reason}")
        output().agent_text("Accepted: #{eval.reason}")
        {:ok, eval}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp filter_config(config, selected_repos) do
    filtered = Enum.filter(config.projects, fn p -> p.repo in selected_repos end)
    %{config | projects: filtered}
  end

  # --- Post-run handlers ---

  defp handle_success(config, ticket, branch, result) do
    Logger.info("Agent succeeded for #{ticket.key}, pushing and creating PRs")
    pr_urls = push_all(config, ticket, branch)

    comment = build_success_comment(result.summary, pr_urls)
    comment_on_ticket(config, ticket, comment)

    # Transition ticket to done status
    transition_name = config.jira_done_transition
    case Golem.Jira.transition_ticket(ticket.key, transition_name, config.jira_base_url) do
      :ok -> Logger.info("Transitioned #{ticket.key} to '#{transition_name}'")
      {:error, reason} -> Logger.warning("Failed to transition #{ticket.key}: #{reason}")
    end

    {:ok, result}
  end

  defp handle_rejection(config, ticket, branch, result) do
    Logger.info("Agent rejected #{ticket.key}: #{result.summary}")
    pr_urls = push_all(config, ticket, branch)

    pr_section = case pr_urls do
      [] -> ""
      urls -> "\n\n**Draft PRs (for review):**\n" <> Enum.map_join(urls, "\n", &"- #{&1}")
    end

    comment = """
    Golem could not complete this ticket.

    **Reason:** #{result.summary}#{pr_section}
    """

    comment_on_ticket(config, ticket, comment)
    {:ok, result}
  end

  defp push_all(config, ticket, branch) do
    output().planning("Pushing branches and creating PRs...")

    config.projects
    |> Enum.map(fn project -> push_and_pr(config, project, ticket, branch) end)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, url} -> url end)
  end

  defp handle_error(config, ticket, reason) do
    Logger.error("Agent errored on #{ticket.key}: #{inspect(reason)}")

    comment = "Golem encountered an error: #{inspect(reason)}"
    comment_on_ticket(config, ticket, comment)
  end

  # --- Push & PR ---

  defp push_and_pr(config, project, ticket, branch) do
    path = project.path

    # Commit any leftover uncommitted changes as a safety net
    maybe_commit_remaining(path, ticket)

    # Check if there are any commits beyond the base branch
    case Golem.Sandbox.exec(
           "cd #{path} && git log origin/#{project.branch_from}..HEAD --oneline 2>/dev/null | head -1",
           timeout: 10_000
         ) do
      {:ok, %{exit_code: 0, output: output}} when byte_size(output) > 0 ->
        with :ok <- push_branch(path, branch),
             {:ok, pr_url} <- create_pr(config, project, ticket, branch) do
          Logger.info("Created PR for #{project.repo}: #{pr_url}")
          {:ok, pr_url}
        else
          {:error, reason} ->
            Logger.error("Failed to push/PR for #{project.repo}: #{reason}")
            {:error, reason}
        end

      _ ->
        Logger.info("No commits in #{project.repo}, skipping PR")
        :no_changes
    end
  end

  defp maybe_commit_remaining(path, ticket) do
    # Clean up temp files the agent may have left behind
    Golem.Sandbox.exec(
      "cd #{path} && git ls-files --others --exclude-standard | grep -E '\\.(sh|tmp|bak|log|patch)$' | xargs -r rm -f",
      timeout: 10_000
    )

    case Golem.Sandbox.exec("cd #{path} && git status --porcelain", timeout: 10_000) do
      {:ok, %{exit_code: 0, output: output}} when byte_size(output) > 0 ->
        message = "[#{ticket.key}] remaining changes"
        Golem.Sandbox.exec(
          "cd #{path} && git add -A && git commit -m '#{escape_shell(message)}'",
          timeout: 30_000
        )

      _ ->
        :ok
    end
  end

  defp push_branch(path, branch) do
    case Golem.Sandbox.exec("cd #{path} && git push -u origin #{branch}", timeout: 60_000) do
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, %{output: out}} -> {:error, "git push failed: #{String.slice(out, 0, 200)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp create_pr(config, project, ticket, branch) do
    repo_slug = project.repo |> String.split("/") |> List.last()

    Golem.Bitbucket.create_draft_pr(config.bitbucket_workspace, repo_slug, %{
      title: "[#{ticket.key}] #{ticket.summary}",
      source_branch: branch,
      destination_branch: project.branch_from,
      description: "Automated by Golem for #{ticket.key}.\n\n#{ticket.description}"
    })
  end

  # --- Goal & context construction ---

  defp build_goal(ticket, config) do
    project_list =
      config.projects
      |> Enum.map(fn p ->
        desc = if p.description, do: " (#{p.description})", else: ""
        "- `#{p.repo}`#{desc} at `#{p.path}`"
      end)
      |> Enum.join("\n")

    labels_section =
      case ticket.labels do
        [] -> nil
        labels -> "**Labels:** #{Enum.join(labels, ", ")}"
      end

    comments_section =
      case ticket.comments do
        [] -> nil
        comments ->
          formatted = Enum.map_join(comments, "\n\n", fn c ->
            "> **#{c.author}:**\n> #{String.replace(c.body, "\n", "\n> ")}"
          end)
          """
          ## Instructions from Comments

          The following comments contain important context and instructions from the team. \
          Pay close attention — these often specify implementation approach, UI patterns to follow, \
          or constraints that are not in the ticket description.

          #{formatted}
          """
      end

    parts = [
      """
      ## #{ticket.key}: #{ticket.summary}

      Everything below is the ticket as written by the team. The description, acceptance criteria, \
      and especially the comments are your primary instructions. Follow them closely — if a comment \
      says "use the same pattern as X", find X and replicate it.
      """,
      labels_section,
      if(ticket.description && ticket.description != "", do: "## Description\n\n#{ticket.description}"),
      if(ticket.acceptance_criteria, do: "## Acceptance Criteria\n\n#{ticket.acceptance_criteria}"),
      comments_section,
      """
      ## Projects

      #{project_list}

      Map each step in your plan to the specific project directory where the changes belong. \
      If the ticket has acceptance criteria, ensure every criterion has a corresponding plan step. \
      If comments reference existing patterns or components, find and study them before planning.
      """
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp build_agents_md(config, branch, ticket) do
    project_list =
      config.projects
      |> Enum.map(fn p ->
        desc = if p.description, do: " — #{p.description}", else: ""
        "- **#{p.repo}** at `#{p.path}`#{desc} (branch: `#{branch}`, base: `#{p.branch_from}`)"
      end)
      |> Enum.join("\n")

    # Read actual AGENTS.md / CLAUDE.md from each project root
    project_docs =
      config.projects
      |> Enum.flat_map(fn p ->
        ["AGENTS.md", "CLAUDE.md"]
        |> Enum.map(fn name ->
          case Golem.Sandbox.exec("cat #{p.path}/#{name} 2>/dev/null", timeout: 5_000) do
            {:ok, %{exit_code: 0, output: content}} when byte_size(content) > 0 ->
              "## #{p.repo} — #{name}\n\n#{String.trim(content)}"
            _ -> nil
          end
        end)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    project_docs_section =
      if project_docs != "" do
        "\n\n## Project Documentation\n\n#{project_docs}"
      else
        ""
      end

    """
    ## Project Layout

    #{project_list}

    ## Git Workflow

    - You are on branch `#{branch}` in all project directories.
    - Make your changes in the appropriate project directory.
    - **Commit frequently** after each logical unit of work:
      ```
      cd /path/to/project && git add -A && git commit -m "[#{ticket.key}] description of change"
      ```
    - Always prefix commit messages with `[#{ticket.key}]`.
    - Do NOT push — the orchestrator handles pushing after you're done.
    - Do NOT modify files outside the project directories listed above.
    #{project_docs_section}
    """
  end

  # --- Helpers ---

  defp comment_on_ticket(config, ticket, body) do
    case Golem.Jira.add_comment(ticket.key, body, config.jira_base_url) do
      :ok -> Logger.info("Commented on #{ticket.key}")
      {:error, reason} -> Logger.error("Failed to comment on #{ticket.key}: #{reason}")
    end
  end

  defp build_success_comment(summary, pr_urls) do
    pr_section =
      case pr_urls do
        [] -> "No code changes were needed."
        urls -> "**Pull Requests:**\n" <> Enum.map_join(urls, "\n", &"- #{&1}")
      end

    """
    Golem completed this ticket.

    **Summary:** #{summary}

    #{pr_section}
    """
  end

  defp escape_shell(str) do
    String.replace(str, "'", "'\\''")
  end
end
