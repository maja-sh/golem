defmodule Golem.Iterate do
  @moduledoc """
  PR feedback iteration loop.

  Given a PR (resolved from a ticket key, a `workspace/repo/id`
  triple, or a full URL), fetch the unresolved reviewer comments
  AND unresolved Bitbucket PR tasks, set up a worktree on the
  existing branch, run the agent with the feedback as the goal,
  push commits back to the same branch, and reply on each
  addressed thread with the commit SHA. The command is
  `mix golem.iterate` — "iterate on a PR" matches how engineers
  normally describe addressing review feedback.

  Companion to `Golem.Jira.Integration` — same pipeline shape, but
  the input is reviewer feedback instead of a fresh ticket. The
  name `review` stays free for a future feature where Golem itself
  reviews PRs (posting comments / LGTM / pointing out bugs).
  """

  require Logger

  defp output, do: Golem.Output.current()

  @doc """
  Run the review pipeline on a fully-resolved PR map (as returned by
  `Golem.Bitbucket.fetch_pull_request/3`).
  """
  def run(pr, opts \\ []) do
    Logger.info("Review pipeline starting for PR #{pr.workspace}/#{pr.repo}/#{pr.id}")

    run_id = opts[:run_id] || Golem.State.new_run_id()
    output().init_display(run_id, "Review: #{pr.workspace}/#{pr.repo}/#{pr.id}")

    output().planning("Fetching review feedback…")

    with {:ok, comments} <- fetch_actionable_comments(pr),
         {:ok, tasks} <- fetch_actionable_tasks(pr),
         :ok <- ensure_some_feedback(comments, tasks),
         {:ok, config} <- Golem.ProjectSetup.load_config_with_jira(),
         project when not is_nil(project) <- find_project_for_pr(config, pr),
         _ = output_feedback_count(pr, comments, tasks),
         _ = output().planning("Setting up worktree on #{pr.source_branch}…"),
         ticket_key = ticket_key_from_branch(pr.source_branch) || "PR-#{pr.id}",
         {:ok, branch, task_config} <-
           Golem.ProjectSetup.setup_iterate_worktree(config, project, pr, ticket_key) do
      output().agent_text("Branch: #{branch}")

      diffs_by_path = fetch_inline_diffs(task_config, pr, comments)
      goal = build_goal(pr, comments, tasks, task_config, diffs_by_path)
      agents_md = build_agents_md(task_config, branch, pr)

      runner_opts =
        opts
        |> Keyword.put(:agents_md, agents_md)
        |> Keyword.put(:run_id, run_id)

      Logger.info("Running review agent for PR #{pr.id}")
      output().planning("Starting agent…")

      case Golem.run(goal, runner_opts) do
        {:ok, %{success: true} = result} ->
          handle_success(task_config, pr, branch, comments, tasks, result)

        {:ok, %{success: false} = result} ->
          Logger.warning("Review agent reported failure: #{inspect(result.summary)}")
          push_branch(task_config, branch)
          {:ok, result}

        {:error, _reason} = err ->
          push_branch(task_config, branch)
          err
      end
    else
      :no_feedback ->
        output().agent_text("No actionable comments or tasks — nothing to do.")
        {:ok, :no_feedback}

      nil ->
        Logger.error("Could not match PR's repo to any configured project")
        output().agent_text("✗ Could not match PR's repo to any configured project")
        {:error, :unknown_project}

      {:error, reason} = err ->
        Logger.error("Review pipeline failed: #{inspect(reason)}")
        output().agent_text("✗ Review pipeline failed: #{inspect(reason)}")
        err
    end
  end

  defp output_feedback_count(pr, comments, tasks) do
    output().agent_text(
      "#{length(comments)} comment(s), #{length(tasks)} task(s) on " <>
        "#{pr.workspace}/#{pr.repo}/#{pr.id}"
    )
  end

  # --- Comment fetching ---

  # Fetch comments, classify each top-level thread as either actionable
  # or awaiting-reviewer based on the latest activity:
  #
  #   - latest comment in the thread is a bot ack ("Addressed in <sha>")
  #     → awaiting reviewer; skip on re-iterate.
  #   - latest comment is a fresh human reply (or the original, if no
  #     replies) → actionable.
  #
  # When a thread is re-activated by a human follow-up, that follow-up
  # is attached as `:follow_up` so the goal can highlight it as the
  # operative instruction (the original comment may have been answered
  # in a way the reviewer is now disputing).
  defp fetch_actionable_comments(pr) do
    case Golem.Bitbucket.list_pr_comments(pr.workspace, pr.repo, pr.id) do
      {:ok, all} ->
        live = Enum.reject(all, & &1.deleted)
        bot_name = (System.get_env("GIT_USER") || "Golem Bot") |> String.downcase()

        # Bitbucket allows nested replies (reply-to-reply). A reviewer
        # who clicks "Reply" on the bot's `Addressed in <sha>` comment
        # makes a comment whose `parent_id` is the bot's id, not the
        # top-level comment's. Walk the parent chain so every
        # descendant is attributed to its root thread — otherwise the
        # bot's ack looks like the latest activity and the thread gets
        # skipped as already-addressed.
        by_id = Map.new(live, &{&1.id, &1})

        descendants_by_root =
          live
          |> Enum.filter(& &1.parent_id)
          |> Enum.group_by(&root_id(&1, by_id))

        actionable =
          live
          |> Enum.filter(&is_nil(&1.parent_id))
          |> Enum.reject(& &1.resolved)
          |> Enum.reject(&(&1.author |> String.downcase() == bot_name))
          |> Enum.flat_map(fn top ->
            descendants = Map.get(descendants_by_root, top.id, [])
            latest = latest_in_thread(top, descendants)

            if bot_ack?(latest) do
              []
            else
              [Map.put(top, :follow_up, latest_human_reply(descendants))]
            end
          end)

        {:ok, actionable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp latest_in_thread(top, []), do: top
  defp latest_in_thread(_top, replies), do: Enum.max_by(replies, & &1.created)

  # Walk parent_ids up to the top-level ancestor. Defends against
  # missing parents (e.g. a deleted comment in the chain) by treating
  # the comment as its own root, and against pathological depth with
  # a hard cap.
  defp root_id(comment, by_id), do: do_root_id(comment, by_id, 0)

  defp do_root_id(comment, _by_id, depth) when depth > 50, do: comment.id
  defp do_root_id(%{parent_id: nil} = comment, _by_id, _depth), do: comment.id

  defp do_root_id(%{parent_id: parent_id} = comment, by_id, depth) do
    case Map.get(by_id, parent_id) do
      nil -> comment.id
      parent -> do_root_id(parent, by_id, depth + 1)
    end
  end

  # Most recent non-bot reply, used to surface the reviewer's latest
  # word on a thread that's been re-opened after a bot ack.
  defp latest_human_reply([]), do: nil

  defp latest_human_reply(replies) do
    replies
    |> Enum.reject(&bot_ack?/1)
    |> case do
      [] -> nil
      list -> Enum.max_by(list, & &1.created)
    end
  end

  defp bot_ack?(%{body: body}) when is_binary(body) do
    String.starts_with?(body, "Addressed in ") or
      String.starts_with?(body, "Addressed task ")
  end

  defp bot_ack?(_), do: false

  # Tasks are the formalized "must do this" version of feedback. We
  # only care about ones that are still UNRESOLVED.
  defp fetch_actionable_tasks(pr) do
    case Golem.Bitbucket.list_pr_tasks(pr.workspace, pr.repo, pr.id) do
      {:ok, all} ->
        {:ok, Enum.filter(all, &(&1.state == "UNRESOLVED"))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_some_feedback([], []), do: :no_feedback
  defp ensure_some_feedback(_, _), do: :ok

  # --- Project / ticket matching ---

  defp find_project_for_pr(config, pr) do
    expected_repo = "#{pr.workspace}/#{pr.repo}"
    Enum.find(config.projects, fn p -> p.repo == expected_repo end)
  end

  # `golem/SA-2100-add-location` → "SA-2100"
  defp ticket_key_from_branch(branch) do
    case Regex.run(~r{^golem/([A-Z]+-\d+)-}, branch) do
      [_, key] -> key
      _ -> nil
    end
  end

  # --- Goal assembly ---

  # For each unique path mentioned in inline comments, fetch the diff
  # against the PR's destination branch in the worktree. Capped per-file
  # so a 5000-line diff doesn't blow the goal context. The agent gets to
  # see what was actually changed at that location instead of having to
  # discover it from the comment's literal wording.
  @diff_max_lines 80

  defp fetch_inline_diffs(task_config, pr, comments) do
    project = List.first(task_config.projects)

    paths =
      comments
      |> Enum.map(& &1.path)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if paths == [] or project == nil do
      %{}
    else
      ensure_destination_fetched(project, pr.destination_branch)

      Enum.reduce(paths, %{}, fn path, acc ->
        case run_diff(project, pr.destination_branch, path) do
          {:ok, diff} -> Map.put(acc, path, diff)
          :error -> acc
        end
      end)
    end
  end

  # The main clone is shallow on the default branch only. We need a
  # deep-enough fetch of the destination branch to compute a meaningful
  # diff against HEAD. Depth 50 covers nearly all PRs without paying for
  # full history.
  defp ensure_destination_fetched(project, dest_branch) do
    cmd =
      "cd #{project.path} && git fetch origin " <>
        "#{dest_branch}:refs/remotes/origin/#{dest_branch} --depth 50 2>/dev/null"

    Golem.Sandbox.exec(cmd, timeout: 120_000)
  end

  defp run_diff(project, dest_branch, path) do
    cmd =
      "cd #{project.path} && git diff origin/#{dest_branch}..HEAD -- #{shell_escape(path)} " <>
        "| head -n #{@diff_max_lines}"

    case Golem.Sandbox.exec(cmd, timeout: 30_000) do
      {:ok, %{exit_code: 0, output: out}} when byte_size(out) > 0 -> {:ok, String.trim(out)}
      _ -> :error
    end
  end

  defp shell_escape(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp build_goal(pr, comments, tasks, task_config, diffs_by_path) do
    project_list =
      task_config.projects
      |> Enum.map(fn p ->
        desc = if p.description, do: " (#{p.description})", else: ""
        "- `#{p.repo}`#{desc} at `#{p.path}`"
      end)
      |> Enum.join("\n")

    {inline_comments, general_comments} =
      Enum.split_with(comments, fn c -> c.path != nil end)

    inline_section =
      if inline_comments == [] do
        nil
      else
        # Group by path so the diff hunk renders once per file, with all
        # comments on that file underneath. Reviewers often use related
        # but non-literal terms ("grpc" for protobuf, "the import" for a
        # specific line) — the diff is the source of truth for what
        # actually changed.
        grouped =
          inline_comments
          |> Enum.group_by(& &1.path)
          |> Enum.map_join("\n\n", fn {path, cs} ->
            comments_block =
              Enum.map_join(cs, "\n\n", fn c ->
                line_part = if c.line, do: ":#{c.line}", else: ""
                base =
                  "**#{c.author}** at `#{path}#{line_part}`:\n> #{quote_body(c.body)}"

                base <> render_follow_up(c)
              end)

            diff_block =
              case Map.get(diffs_by_path, path) do
                nil -> ""
                "" -> ""
                diff -> "\n\nDiff at `#{path}` (vs `#{pr.destination_branch}`):\n\n```diff\n#{diff}\n```"
              end

            "### `#{path}`\n\n#{comments_block}#{diff_block}"
          end)

        "## Inline comments\n\n" <>
          "The diff hunks below each file are the source of truth for what " <>
          "the reviewer is reacting to. Read them before interpreting the " <>
          "comment — the comment may use related-but-different terminology.\n\n" <>
          grouped
      end

    general_section =
      if general_comments == [] do
        nil
      else
        formatted =
          Enum.map_join(general_comments, "\n\n", fn c ->
            "**#{c.author}** (PR-level):\n> #{quote_body(c.body)}#{render_follow_up(c)}"
          end)

        "## PR-level comments\n\n#{formatted}"
      end

    tasks_section =
      if tasks == [] do
        nil
      else
        formatted =
          Enum.map_join(tasks, "\n\n", fn t ->
            "**Task ##{t.id}** by #{t.creator}:\n> #{quote_body(t.body)}"
          end)

        "## PR Tasks (concrete action items)\n\n" <>
          "These are formalized to-dos the reviewer attached to the PR. " <>
          "Treat them as binding unless you have a strong reason to push back.\n\n" <>
          formatted
      end

    parts = [
      """
      ## PR Review: #{pr.workspace}/#{pr.repo}/#{pr.id}

      **Title:** #{pr.title}
      **Branch:** `#{pr.source_branch}` → `#{pr.destination_branch}`
      **URL:** #{pr.url}

      A human reviewer left the feedback below on this pull request. \
      Your job is to address it: apply concrete suggestions, complete \
      the tasks, answer questions where you can, and skip nits or \
      "LGTM" noise. The branch is already checked out as a worktree — \
      just commit and push.

      ## How to handle each item

      - **PR Task** → these are the strongest signal. Treat as binding \
        unless plainly wrong; apply, then commit.
      - **Suggested change** ("use X instead", a ` ```suggestion ` \
        block) → apply it.
      - **Question** ("why X?", "is this correct for Z?") → if you can \
        answer from the code, fix the underlying confusion (rename a \
        variable, add a comment, simplify the logic). Don't just leave \
        the question hanging.
      - **Nit / opinion** ("could be cleaner") → use judgment; apply if \
        cheap and clearly an improvement, otherwise skip.
      - **Genuinely ambiguous** → call `ask_user` if Discord is wired \
        up; otherwise make a defensible choice and explain it in the \
        commit message.

      Commit each addressed item as its own commit when reasonable, \
      with a message that references the reviewer's name (e.g. \
      "Address Alice's note on tenant scoping"). Push at the end. \
      Don't mark threads or tasks resolved — that's the reviewer's \
      call. We will reply with `Addressed in <sha>` automatically \
      after you finish.

      ## Tests are mandatory for fixes

      If a comment or task points at a bug or missing behavior, the \
      fix MUST land with a regression test that fails on the old code \
      and passes on your fix. If a comment says "this fails when X", \
      add a test for X. Pure-style nits (formatting, naming, dead \
      code removal) don't need tests; behavior changes always do.

      ## Scope discipline (STRICT)

      Address ONLY the comments and tasks listed above. Do NOT do \
      additional work that wasn't requested:

      - **Do NOT** bump dependencies, fix CVEs, or update packages — \
        even if a CI bot comment lists vulnerable packages. Those \
        warnings are informational; the operator schedules security \
        bumps separately.
      - **Do NOT** refactor, rename, or "improve" code that wasn't \
        called out by a reviewer.
      - **Do NOT** fix unrelated bugs you happen to notice.
      - **Do NOT** reformat, run linters, or clean up imports outside \
        files you're already touching for an explicit comment.

      If a comment quotes a CI bot's test output or vulnerability \
      report, the actionable part is the failing tests / fixed \
      behavior — NOT the CVE bumps. When in doubt, skip and call \
      `ask_user` if Discord is wired up; otherwise leave it.

      Out-of-scope changes waste budget and produce surprise diffs \
      the reviewer didn't ask for. Stick to the list.
      """,
      tasks_section,
      inline_section,
      general_section,
      """
      ## Project layout

      #{project_list}
      """,
      project_instructions_section(task_config)
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp quote_body(text), do: String.replace(text, "\n", "\n> ")

  # When a thread has been reopened by a human follow-up after a prior
  # bot ack, the follow-up is the operative instruction — the original
  # comment may have been answered in a way the reviewer is now
  # disputing. Surface it prominently.
  defp render_follow_up(%{follow_up: %{} = fu}) do
    "\n\n_⤷ Most recent reply (THIS supersedes the original — address THIS):_\n" <>
      "**#{fu.author}**:\n> #{quote_body(fu.body)}"
  end

  defp render_follow_up(_), do: ""

  # Mirror the Jira pipeline: per-project `instructions:` are mandatory
  # context and apply during iteration too (flaky-test handling, repo-
  # specific verification rules, etc).
  defp project_instructions_section(task_config) do
    body =
      task_config.projects
      |> Enum.filter(& &1.instructions)
      |> Enum.map(fn p -> "### #{p.repo}\n\n#{p.instructions}" end)
      |> Enum.join("\n\n")

    if body == "" do
      nil
    else
      "## Project-Specific Instructions\n\n" <>
        "These are mandatory instructions per project. Follow them exactly.\n\n" <>
        body
    end
  end

  defp build_agents_md(task_config, branch, pr) do
    project_list =
      task_config.projects
      |> Enum.map(fn p ->
        desc = if p.description, do: " — #{p.description}", else: ""
        "- **#{p.repo}** at `#{p.path}`#{desc} (branch: `#{branch}`)"
      end)
      |> Enum.join("\n")

    """
    ## Review context

    You are addressing reviewer feedback on PR #{pr.url}. The branch \
    `#{branch}` is already checked out and contains the original \
    implementation. `git log` and `git diff origin/#{pr.destination_branch}..HEAD` \
    will show what was already done.

    ## Projects

    #{project_list}
    """
  end

  # --- Success path: push + reply on each thread ---

  defp handle_success(task_config, pr, branch, comments, tasks, result) do
    output().planning("Pushing branch and posting replies…")

    project = List.first(task_config.projects)

    with {:ok, head_sha} <- push_branch_and_get_head(project, branch) do
      # Reply once per parent comment, even if both a comment and a task
      # point at the same thread. Tasks with no parent comment get a
      # top-level PR comment that names the task ID.
      comment_parents = Enum.map(comments, & &1.id)

      task_parents =
        tasks
        |> Enum.map(& &1.comment_id)
        |> Enum.reject(&is_nil/1)

      parent_ids = (comment_parents ++ task_parents) |> Enum.uniq()
      orphan_tasks = Enum.filter(tasks, &is_nil(&1.comment_id))

      # Per-thread replies are short acks. The full summary goes in a
      # single PR-level comment below — no point pasting the same
      # paragraph onto every thread.
      thread_replies =
        Enum.reduce(parent_ids, 0, fn parent_id, acc ->
          case Golem.Bitbucket.add_pr_comment(
                 pr.workspace,
                 pr.repo,
                 pr.id,
                 thread_reply_body(head_sha),
                 parent_id: parent_id
               ) do
            :ok ->
              acc + 1

            {:error, reason} ->
              Logger.warning("Failed to reply on thread #{parent_id}: #{inspect(reason)}")
              acc
          end
        end)

      orphan_replies =
        Enum.reduce(orphan_tasks, 0, fn t, acc ->
          body = "Addressed task ##{t.id} in `#{head_sha}`."

          case Golem.Bitbucket.add_pr_comment(pr.workspace, pr.repo, pr.id, body) do
            :ok ->
              acc + 1

            {:error, reason} ->
              Logger.warning("Failed to reply for task ##{t.id}: #{inspect(reason)}")
              acc
          end
        end)

      maybe_post_summary(pr, head_sha, result)

      total_targets = length(parent_ids) + length(orphan_tasks)
      total_sent = thread_replies + orphan_replies
      Logger.info("Posted #{total_sent}/#{total_targets} addressed replies")
      output().agent_text("Posted #{total_sent}/#{total_targets} addressed replies")
      {:ok, result}
    end
  end

  defp thread_reply_body(head_sha), do: "Addressed in `#{head_sha}`."

  defp maybe_post_summary(_pr, _sha, %{summary: summary}) when summary in [nil, ""], do: :skip

  defp maybe_post_summary(pr, head_sha, result) do
    body = "**Iteration summary** (head `#{head_sha}`)\n\n#{result.summary}"

    case Golem.Bitbucket.add_pr_comment(pr.workspace, pr.repo, pr.id, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to post PR-level summary: #{inspect(reason)}")
        :error
    end
  end

  defp push_branch_and_get_head(project, branch) do
    with :ok <- push_branch_inner(project, branch),
         {:ok, sha} <- head_sha(project) do
      {:ok, sha}
    end
  end

  defp push_branch(task_config, branch) do
    project = List.first(task_config.projects)
    push_branch_inner(project, branch)
  end

  defp push_branch_inner(project, branch) do
    case Golem.Sandbox.exec("cd #{project.path} && git push -u origin #{branch}", timeout: 60_000) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{output: out}} ->
        {:error, "git push failed: #{String.slice(out, 0, 300)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp head_sha(project) do
    case Golem.Sandbox.exec("cd #{project.path} && git rev-parse --short HEAD", timeout: 5_000) do
      {:ok, %{exit_code: 0, output: out}} -> {:ok, String.trim(out)}
      _ -> {:error, :head_sha_unavailable}
    end
  end

  # --- Resolution helpers (used by Mix.Tasks.Golem.Review) ---

  @doc """
  Parse a single positional arg into a partial PR ref.

  Recognized shapes:

    * `"SA-2100"` → `{:ticket, "SA-2100"}`
    * `"hrdl/api/3480"` → `{:pr_path, "hrdl", "api", 3480}`
    * `"https://bitbucket.org/hrdl/api/pull-requests/3480"` → same
  """
  def parse_arg(arg) when is_binary(arg) do
    cond do
      Regex.match?(~r/^[A-Z]+-\d+$/, arg) ->
        {:ticket, arg}

      m = Regex.run(~r{^https?://bitbucket\.org/([^/]+)/([^/]+)/pull-requests/(\d+)}, arg) ->
        [_, ws, repo, id] = m
        {:pr_path, ws, repo, String.to_integer(id)}

      m = Regex.run(~r{^([^/]+)/([^/]+)/(\d+)$}, arg) ->
        [_, ws, repo, id] = m
        {:pr_path, ws, repo, String.to_integer(id)}

      true ->
        {:error, :unrecognized}
    end
  end

  @doc """
  Resolve a parsed arg into a fully-fetched PR map.

  When the arg is a ticket key, search every configured project's repo
  for an OPEN PR whose source branch starts with `golem/<KEY>-`. Errors
  if zero or more-than-one match.
  """
  def resolve(parsed, config) do
    case parsed do
      {:pr_path, ws, repo, id} ->
        Golem.Bitbucket.fetch_pull_request(ws, repo, id)

      {:ticket, key} ->
        resolve_ticket(key, config)

      {:error, _} = err ->
        err
    end
  end

  defp resolve_ticket(key, config) do
    matches =
      config.projects
      |> Enum.flat_map(fn p ->
        [ws, repo] = String.split(p.repo, "/", parts: 2)

        case Golem.Bitbucket.list_pull_requests(ws, repo,
               state: "OPEN",
               branch_prefix: "golem/#{key}-"
             ) do
          {:ok, prs} -> prs
          {:error, _} -> []
        end
      end)

    case matches do
      [] -> {:error, "No open PR found for ticket #{key}"}
      [pr] -> {:ok, pr}
      many -> {:error, "Multiple open PRs found for #{key}: #{inspect(Enum.map(many, & &1.url))}"}
    end
  end

  @doc """
  Diagnose comment classification on a PR. Returns a list of
  per-thread maps showing:

    * whether the top-level was rejected (resolved / bot-authored)
    * latest activity in the thread
    * whether the thread was classified as actionable, and why

  Used by `mix golem.iterate --debug` to surface why a reply isn't
  being picked up as actionable feedback.
  """
  def diagnose(pr) do
    case Golem.Bitbucket.list_pr_comments(pr.workspace, pr.repo, pr.id) do
      {:ok, all} ->
        live = Enum.reject(all, & &1.deleted)
        bot_name = (System.get_env("GIT_USER") || "Golem Bot") |> String.downcase()
        by_id = Map.new(live, &{&1.id, &1})

        descendants_by_root =
          live
          |> Enum.filter(& &1.parent_id)
          |> Enum.group_by(&root_id(&1, by_id))

        threads =
          live
          |> Enum.filter(&is_nil(&1.parent_id))
          |> Enum.map(fn top ->
            descendants = Map.get(descendants_by_root, top.id, [])
            latest = latest_in_thread(top, descendants)
            top_is_bot = String.downcase(top.author) == bot_name

            {actionable?, reason} =
              cond do
                top.resolved -> {false, "top-level resolved"}
                top_is_bot -> {false, "top-level authored by bot"}
                bot_ack?(latest) -> {false, "latest is bot ack"}
                true -> {true, "actionable"}
              end

            %{
              top: top,
              descendants: descendants,
              latest: latest,
              actionable: actionable?,
              reason: reason
            }
          end)

        {:ok, threads}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  List all open bot-authored PRs across configured projects, with
  unresolved item counts (comments + tasks). Used by the bare
  `mix golem.iterate` invocation to show what's actionable without
  doing anything.
  """
  def actionable_summary(config) do
    config.projects
    |> Enum.flat_map(fn p ->
      [ws, repo] = String.split(p.repo, "/", parts: 2)

      case Golem.Bitbucket.list_pull_requests(ws, repo,
             state: "OPEN",
             branch_prefix: "golem/"
           ) do
        {:ok, prs} -> Enum.map(prs, fn pr -> {p, pr} end)
        {:error, _} -> []
      end
    end)
    |> Enum.map(fn {_project, pr} ->
      # Reuse the thread-aware filter so listings reflect what
      # `mix golem.iterate <pr>` would actually act on.
      actionable_comments =
        case fetch_actionable_comments(pr) do
          {:ok, list} -> length(list)
          _ -> 0
        end

      unresolved_tasks =
        case Golem.Bitbucket.list_pr_tasks(pr.workspace, pr.repo, pr.id) do
          {:ok, tasks} -> Enum.count(tasks, &(&1.state == "UNRESOLVED"))
          _ -> 0
        end

      %{
        pr: pr,
        unresolved: actionable_comments + unresolved_tasks,
        tasks: unresolved_tasks
      }
    end)
    |> Enum.sort_by(& &1.unresolved, :desc)
  end
end
