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
    nudge = normalize_nudge(opts[:nudge])
    if nudge, do: output().agent_text("Nudge: #{nudge}")

    with {:ok, config} <- Golem.ProjectSetup.load_config_with_jira(),
         {:ok, ticket} <- Golem.Jira.fetch_ticket(ticket_key, config.jira_base_url),
         :ok <- (output().agent_text("#{ticket.key}: #{ticket.summary}"); :ok),
         attachment_blocks = Golem.Jira.attachment_blocks(ticket),
         {:ok, evaluation} <- evaluate_or_skip(ticket, config, skip_eval, attachment_blocks, nudge) do

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
        goal = build_goal(ticket, task_config, nudge)
        agents_md = build_agents_md(task_config, branch, ticket, visual_verify)

        runner_opts =
          opts
          |> Keyword.put(:agents_md, agents_md)
          |> Keyword.put(:run_id, run_id)
          |> Keyword.put(:initial_cost, eval_cost)
          |> Keyword.put(:attachment_blocks, attachment_blocks)

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

  defp evaluate_or_skip(_ticket, config, true, _attachment_blocks, _nudge) do
    output().planning("Skipping evaluation (--force)")
    all_repos = Enum.map(config.projects, & &1.repo)
    {:ok, %{selected_projects: all_repos}}
  end

  defp evaluate_or_skip(ticket, config, false, attachment_blocks, nudge) do
    evaluate_and_filter(ticket, config, attachment_blocks, nudge)
  end

  defp evaluate_and_filter(ticket, config, attachment_blocks, nudge) do
    Logger.info("Evaluating ticket #{ticket.key}...")
    output().planning("Evaluating ticket...")

    case Golem.Jira.Evaluator.evaluate(ticket, config,
           attachment_blocks: attachment_blocks,
           nudge: nudge
         ) do
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
    pr_body = build_pr_body(ticket, :success, result.summary)
    pr_urls = push_all(config, ticket, branch, pr_body)

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
    pr_body = build_pr_body(ticket, :rejected, result.summary)
    pr_urls = push_all(config, ticket, branch, pr_body)

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
    pr_body = build_pr_body(ticket, :paused, reason)
    pr_urls = push_all(config, ticket, branch, pr_body)

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

  defp push_all(config, ticket, branch, pr_body) do
    output().planning("Pushing branches and creating PRs...")

    config.projects
    |> Enum.map(fn project -> push_and_pr(config, project, ticket, branch, pr_body) end)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, url} -> url end)
  end

  defp handle_error(config, ticket, reason) do
    Logger.error("Agent errored on #{ticket.key}: #{inspect(reason)}")

    comment = "Golem encountered an error: #{inspect(reason)}"
    comment_on_ticket(config, ticket, comment)
  end

  # --- Push & PR ---

  defp push_and_pr(config, project, ticket, branch, pr_body) do
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
             {:ok, pr_url} <- create_pr(config, project, ticket, branch, pr_body) do
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

  defp create_pr(config, project, ticket, branch, pr_body) do
    repo_slug = project.repo |> String.split("/") |> List.last()

    Golem.Bitbucket.create_draft_pr(config.bitbucket_workspace, repo_slug, %{
      title: "[#{ticket.key}] #{ticket.summary}",
      source_branch: branch,
      destination_branch: project.branch_from,
      description: pr_body
    })
  end

  # Body shown on the Bitbucket PR. Mirrors what we put on the Jira
  # ticket (summary + caveats) so a reviewer reading the PR sees the
  # same context the Jira watcher does — without having to click
  # through to find it.
  defp build_pr_body(ticket, status, summary) do
    header =
      case status do
        :success -> "Golem completed this ticket."
        :rejected -> "Golem could not complete this ticket — see Summary below."
        :paused -> "Golem run paused — see Summary below. Work may be incomplete."
      end

    summary_section =
      case summary do
        s when is_binary(s) and s != "" -> "## Summary\n\n#{s}"
        _ -> nil
      end

    description_section =
      case ticket.description do
        d when is_binary(d) and d != "" -> "## Original ticket\n\n#{d}"
        _ -> nil
      end

    [header, summary_section, description_section, "_Automated by Golem for #{ticket.key}._"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # --- Goal & context construction ---

  defp build_goal(ticket, config, nudge) do
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

    attachments_section = build_attachments_section(ticket)

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

    nudge_section =
      if nudge do
        """
        ## Operator note

        #{nudge}

        This is a direct instruction from the operator who started this \
        run. It overrides any conflicting interpretation of the ticket — \
        if the description offers multiple approaches, pick the one this \
        note specifies; if it resolves an ambiguity, treat the ambiguity \
        as resolved and don't relitigate it.
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
      nudge_section,
      labels_section,
      if(ticket.description && ticket.description != "", do: "## Description\n\n#{ticket.description}"),
      if(ticket.acceptance_criteria, do: "## Acceptance Criteria\n\n#{ticket.acceptance_criteria}"),
      attachments_section,
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

  # --- Attachments ---

  # Human-readable bytes: "18 KB", "2.3 MB"
  defp fmt_size(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp fmt_size(bytes) when is_integer(bytes) and bytes >= 1024,
    do: "#{div(bytes, 1024)} KB"

  defp fmt_size(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp fmt_size(_), do: "?"

  defp build_attachments_section(%{attachments: attachments}) when attachments != [] do
    images =
      Golem.Jira.image_attachments(attachments) |> Enum.take(Golem.Jira.max_image_attachments())

    texts =
      (Golem.Jira.text_attachments(attachments) -- images)
      |> Enum.take(Golem.Jira.max_text_attachments())

    others = attachments -- images -- texts

    image_lines =
      Enum.map(images, fn a ->
        "- `#{a.filename}` (#{a.mime_type}, #{fmt_size(a.size)}) — **embedded below as an image**"
      end)

    text_lines =
      Enum.map(texts, fn a ->
        "- `#{a.filename}` (#{a.mime_type}, #{fmt_size(a.size)}) — **embedded below as text**"
      end)

    other_lines =
      Enum.map(others, fn a ->
        "- `#{a.filename}` (#{a.mime_type}, #{fmt_size(a.size)}) — binary/oversized, contents unavailable"
      end)

    lines = image_lines ++ text_lines ++ other_lines

    if lines == [] do
      nil
    else
      "## Attachments\n\n" <>
        Enum.join(lines, "\n") <>
        "\n\nAttachments on this ticket are embedded as content blocks in this message — read them as you would the description. Treat them as primary context; the human often screenshots a UI state or attaches a log/CSV that's hard to summarise in prose."
    end
  end

  defp build_attachments_section(_), do: nil

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

  defp normalize_nudge(nil), do: nil
  defp normalize_nudge(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
