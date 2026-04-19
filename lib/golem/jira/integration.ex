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

    # Start the TUI early so the status bar (spinner, elapsed, cost)
    # is visible during fetch/eval/setup, not just once the runner
    # loop begins. The goal blurb is refined later; the ticket key is
    # enough for now.
    run_id = opts[:run_id] || Golem.State.new_run_id()
    output().init_display(run_id, "Jira: #{ticket_key}")

    # Show MCP server status
    mcp_status = Golem.MCP.status()
    if mcp_status != [] do
      mcp_lines = Enum.map_join(mcp_status, "\n", fn
        {:ok, name, count} -> "#{name} · ✓ #{count} tools"
        {:error, name, reason} -> "#{name} · ✗ #{reason}"
        {:error, reason} -> "✗ #{reason}"
      end)
      output().agent_text("MCP: #{mcp_lines}")
    end

    output().planning("Fetching ticket #{ticket_key}...")

    skip_eval = Keyword.get(opts, :skip_eval, false)

    with {:ok, config} <- Golem.ProjectSetup.load_config_with_jira(),
         {:ok, ticket} <- Golem.Jira.fetch_ticket(ticket_key, config.jira_base_url),
         :ok <- (output().agent_text("#{ticket.key}: #{ticket.summary}"); :ok),
         {:ok, evaluation} <- evaluate_or_skip(ticket, config, skip_eval) do

      # Fold pre-flight evaluator spend into the run's initial cost so
      # the final total matches what actually hit the Anthropic bill.
      eval_cost = Map.get(evaluation, :cost, 0.0)
      if eval_cost > 0, do: output().update_cost("$#{:erlang.float_to_binary(eval_cost, decimals: 4)}")

      selected_config = filter_config(config, evaluation.selected_projects)
      projects_label = Enum.map_join(selected_config.projects, ", ", & &1.repo)
      Logger.info("Selected projects: #{projects_label}")
      output().planning("Selected projects: #{projects_label}")

      output().planning("Setting up projects...")
      with {:ok, branch, task_config} <- Golem.ProjectSetup.setup_projects(selected_config, ticket.key, ticket.summary) do
        output().agent_text("Branch: #{branch}")

        # Use task_config which has worktree paths instead of main clone paths
        visual_verify = Keyword.get(opts, :visual_verify, false)
        goal = build_goal(ticket, task_config)
        agents_md = build_agents_md(task_config, branch, ticket, visual_verify)

        runner_opts =
          opts
          |> Keyword.put(:agents_md, agents_md)
          |> Keyword.put(:run_id, run_id)
          |> Keyword.put(:initial_cost, eval_cost)

        Logger.info("Running agent for #{ticket_key}: #{ticket.summary}")
        output().planning("Starting agent...")

        case Golem.run(goal, runner_opts) do
          {:ok, %{success: true} = result} ->
            handle_success(task_config, ticket, branch, result)

          {:ok, %{success: false} = result} ->
            handle_rejection(task_config, ticket, branch, result)

          {:error, :max_steps_reached} = err ->
            handle_paused(task_config, ticket, branch, "max steps reached")
            err

          {:error, :budget_exceeded} = err ->
            handle_paused(task_config, ticket, branch, "cost budget exceeded")
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

  # Push whatever commits exist when the run was paused (step limit or
  # budget). The work is real and committed — capture it as a draft PR
  # so a human can review or the run can be resumed with more budget.
  defp handle_paused(config, ticket, branch, reason) do
    Logger.info("Agent paused for #{ticket.key} (#{reason}); pushing any committed work")
    pr_urls = push_all(config, ticket, branch)

    pr_section = case pr_urls do
      [] -> "\n\nNo commits were pushed — either nothing was committed yet, or the push failed (check `logs/golem.log`)."
      urls -> "\n\n**Draft PRs (for review):**\n" <> Enum.map_join(urls, "\n", &"- #{&1}")
    end

    comment = """
    Golem run paused — #{reason}.

    Any committed work has been pushed as draft PR(s). You can review the diff and either merge, or resume the run with `mix golem.resume <run_id>` (and a higher `--budget` / `--max-steps` if needed).#{pr_section}
    """

    comment_on_ticket(config, ticket, comment)
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
          output().pr_opened(project.repo, pr_url)
          Golem.Events.emit(:pr_opened, %{repo: project.repo, url: pr_url})
          {:ok, pr_url}
        else
          {:error, reason} ->
            Logger.error("Failed to push/PR for #{project.repo}: #{reason}")
            {:error, reason}
        end

      _ ->
        output().pr_skipped(project.repo, "nothing to push")
        Golem.Events.emit(:pr_skipped, %{repo: project.repo, reason: "no_commits"})
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

    ask_human_label? = Enum.any?(ticket.labels, &(String.downcase(&1) == "ask-human"))
    discord_available? = System.get_env("DISCORD_TOKEN") not in [nil, ""]
    operator_name = operator_display_name()

    ask_user_section =
      cond do
        not discord_available? ->
          nil

        ask_human_label? ->
          """
          ## Operator is watching

          This ticket is tagged **`ask-human`**: #{operator_name} explicitly \
          flagged it as one where human judgment is likely needed. Call \
          `ask_user` freely for any genuine ambiguity — choosing between \
          architectural approaches, interpreting a vague acceptance \
          criterion, or confirming which existing pattern to copy. \
          Don't burn 20 steps exploring a fork when a 30-second reply \
          can settle it. Keep questions focused: one decision, one or two \
          choices plus your recommendation.
          """

        true ->
          """
          ## Fast feedback is available

          You can call `ask_user` to reach #{operator_name} on Discord for \
          a fast answer. Use it **only** when a wrong guess would waste \
          significant budget — e.g. architectural forks, genuinely \
          ambiguous acceptance criteria, or confirming a destructive \
          action. Do NOT use it for small UI details or things you can \
          reasonably infer from existing code. If in doubt, make a \
          defensible choice and document it; errors get caught at PR review.
          """
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

      **Type:** #{ticket.issue_type} | **Priority:** #{ticket.priority}

      This ticket was written by a human and may be incomplete — missing \
      edge cases, ambiguous UI details, or phrasing that makes sense to \
      the author but not to you. That's expected. Read the description, \
      acceptance criteria, and comments carefully; they are your primary \
      instructions. If a comment says "use the same pattern as X", find \
      X and replicate it. Where the ticket is genuinely silent, make a \
      reasonable interpretation and move on — mistakes surface in code \
      review and the author will push back there.
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
      """,
      ask_user_section
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # Human-readable name for the operator who receives `ask_user`
  # prompts on Discord. Prefers an explicit `GIT_USER` env, falls back
  # to the local-part of `JIRA_EMAIL` title-cased, finally "the operator".
  defp operator_display_name do
    cond do
      (name = System.get_env("GIT_USER")) not in [nil, ""] ->
        name

      (email = System.get_env("JIRA_EMAIL")) not in [nil, ""] ->
        email |> String.split("@") |> hd() |> String.capitalize()

      true ->
        "the operator"
    end
  end

  defp build_agents_md(config, branch, ticket, visual_verify) do
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

    project_instructions =
      config.projects
      |> Enum.filter(& &1.instructions)
      |> Enum.map(fn p -> "### #{p.repo}\n\n#{p.instructions}" end)
      |> Enum.join("\n\n")

    instructions_section =
      if project_instructions != "" do
        "\n\n## Project-Specific Instructions\n\nThese are mandatory instructions per project. Follow them exactly.\n\n#{project_instructions}"
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
    #{instructions_section}
    #{if visual_verify, do: "\n## Visual Verification REQUIRED\n\nThe operator has requested visual browser verification for this task. Before calling `done`, you MUST start the dev server and use the `browse` tool to verify your changes render correctly in the browser. This is not optional.", else: "\n## Verification\n\nUse code verification (build, syntax check, tests) unless you created new UI components or changed layout/styling. Do NOT start the dev server or use the browser for non-visual changes like translations, store logic, or config changes — it wastes time and tokens."}
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
