defmodule Golem.Iterate do
  @moduledoc """
  PR feedback iteration loop.

  Given a PR (resolved from a ticket key, a `workspace/repo/id`
  triple, or a full URL), fetch the unresolved reviewer comments,
  set up a worktree on the existing branch, run the agent with
  the comments as the goal, push commits back to the same branch,
  and reply on each addressed thread with the commit SHA. The
  command is `mix golem.iterate` — "iterate on a PR" matches how
  engineers normally describe addressing review feedback.

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

    output().planning("Fetching review comments…")

    with {:ok, comments} <- fetch_actionable_comments(pr),
         :ok <- ensure_some_comments(comments),
         {:ok, config} <- Golem.ProjectSetup.load_config_with_jira(),
         project when not is_nil(project) <- find_project_for_pr(config, pr) do
      ticket_key = ticket_key_from_branch(pr.source_branch) || "PR-#{pr.id}"

      output().agent_text(
        "#{length(comments)} unresolved comment(s) on #{pr.workspace}/#{pr.repo}/#{pr.id}"
      )

      output().planning("Setting up worktree on #{pr.source_branch}…")

      with {:ok, branch, task_config} <-
             Golem.ProjectSetup.setup_iterate_worktree(config, project, pr, ticket_key) do
        output().agent_text("Branch: #{branch}")

        goal = build_goal(pr, comments, task_config)
        agents_md = build_agents_md(task_config, branch, pr)

        runner_opts =
          opts
          |> Keyword.put(:agents_md, agents_md)
          |> Keyword.put(:run_id, run_id)

        Logger.info("Running review agent for PR #{pr.id}")
        output().planning("Starting agent…")

        case Golem.run(goal, runner_opts) do
          {:ok, %{success: true} = result} ->
            handle_success(task_config, pr, branch, comments, result)

          {:ok, %{success: false} = result} ->
            Logger.warning("Review agent reported failure: #{inspect(result.summary)}")
            push_branch(task_config, branch)
            {:ok, result}

          {:error, _reason} = err ->
            push_branch(task_config, branch)
            err
        end
      end
    else
      :no_comments ->
        output().agent_text("No actionable unresolved comments — nothing to do.")
        {:ok, :no_comments}

      nil ->
        Logger.error("Could not match PR's repo to any configured project")
        {:error, :unknown_project}

      {:error, reason} = err ->
        Logger.error("Review pipeline failed: #{inspect(reason)}")
        err
    end
  end

  # --- Comment fetching ---

  # Pull all comments, then keep the ones a human reviewer left that
  # haven't been resolved yet. Bot replies and replies-to-replies
  # don't count as actionable.
  defp fetch_actionable_comments(pr) do
    case Golem.Bitbucket.list_pr_comments(pr.workspace, pr.repo, pr.id) do
      {:ok, all} ->
        bot_name = (System.get_env("GIT_USER") || "Golem Bot") |> String.downcase()

        actionable =
          all
          |> Enum.reject(& &1.deleted)
          |> Enum.reject(& &1.resolved)
          |> Enum.reject(&(&1.author |> String.downcase() == bot_name))
          # A reply is itself a thread continuation, not an actionable
          # top-level comment. We consider any comment that isn't itself
          # a reply as potentially actionable.
          |> Enum.filter(&is_nil(&1.parent_id))

        {:ok, actionable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_some_comments([]), do: :no_comments
  defp ensure_some_comments(_), do: :ok

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

  defp build_goal(pr, comments, task_config) do
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
        formatted =
          Enum.map_join(inline_comments, "\n\n", fn c ->
            line_part = if c.line, do: ":#{c.line}", else: ""
            "**#{c.author}** on `#{c.path}#{line_part}`:\n> #{quote_body(c.body)}"
          end)

        "## Inline comments\n\n#{formatted}"
      end

    general_section =
      if general_comments == [] do
        nil
      else
        formatted =
          Enum.map_join(general_comments, "\n\n", fn c ->
            "**#{c.author}** (PR-level):\n> #{quote_body(c.body)}"
          end)

        "## PR-level comments\n\n#{formatted}"
      end

    parts = [
      """
      ## PR Review: #{pr.workspace}/#{pr.repo}/#{pr.id}

      **Title:** #{pr.title}
      **Branch:** `#{pr.source_branch}` → `#{pr.destination_branch}`
      **URL:** #{pr.url}

      A human reviewer left the comments below on this pull request. \
      Your job is to address them: apply concrete suggestions, answer \
      questions where you can, and skip nits or "LGTM" noise. The branch \
      is already checked out as a worktree — just commit and push.

      ## How to handle each comment

      - **Suggested change** ("use X instead", "this should be Y", a \
        ` ```suggestion ` block) → apply it.
      - **Question** ("why X?", "is this correct for Z?") → if you can \
        answer from the code, fix the underlying confusion (rename a \
        variable, add a comment, simplify the logic). Don't just leave \
        the question hanging.
      - **Nit / opinion** ("could be cleaner") → use judgment; apply if \
        cheap and clearly an improvement, otherwise skip.
      - **Genuinely ambiguous** → call `ask_user` if Discord is wired \
        up; otherwise make a defensible choice and explain it in the \
        commit message.

      Commit each addressed comment as its own commit when reasonable, \
      with a message that references the reviewer's name (e.g. \
      "Address Alice's note on tenant scoping"). Push at the end. \
      Don't mark threads resolved — that's the reviewer's call. We \
      will reply with `Addressed in <sha>` automatically after you \
      finish.
      """,
      inline_section,
      general_section,
      """
      ## Project layout

      #{project_list}
      """
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp quote_body(text), do: String.replace(text, "\n", "\n> ")

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

  defp handle_success(task_config, pr, branch, comments, result) do
    output().planning("Pushing branch and posting replies…")

    project = List.first(task_config.projects)

    with {:ok, head_sha} <- push_branch_and_get_head(project, branch) do
      reply_count =
        Enum.reduce(comments, 0, fn c, acc ->
          case Golem.Bitbucket.add_pr_comment(
                 pr.workspace,
                 pr.repo,
                 pr.id,
                 reply_body(head_sha, result),
                 parent_id: c.id
               ) do
            :ok ->
              acc + 1

            {:error, reason} ->
              Logger.warning("Failed to reply to comment #{c.id}: #{inspect(reason)}")
              acc
          end
        end)

      Logger.info("Replied on #{reply_count}/#{length(comments)} threads")
      output().agent_text("Replied on #{reply_count}/#{length(comments)} threads")
      {:ok, result}
    end
  end

  defp reply_body(head_sha, result) do
    summary = String.slice(result.summary || "", 0, 200)
    "Addressed in `#{head_sha}`.\n\n#{summary}"
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
  List all open bot-authored PRs across configured projects, with
  unresolved-comment counts. Used by the bare `mix golem.review`
  invocation to show what's actionable without doing anything.
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
      unresolved =
        case Golem.Bitbucket.list_pr_comments(pr.workspace, pr.repo, pr.id) do
          {:ok, comments} ->
            comments
            |> Enum.reject(& &1.deleted)
            |> Enum.reject(& &1.resolved)
            |> Enum.filter(&is_nil(&1.parent_id))
            |> length()

          _ ->
            0
        end

      %{pr: pr, unresolved: unresolved}
    end)
    |> Enum.sort_by(& &1.unresolved, :desc)
  end
end
