# Jira & Bitbucket Workflow

## Configuration

Jira settings live under the `jira:` block in `.golem/config.yml`:

```yaml
jira:
  base_url: https://yoursite.atlassian.net
  done_transition: "Pull Request / Deployable"   # optional, default "Done"
```

## Run a ticket

Run a ticket with `mix golem.run --jira SA-1111`. The pipeline:

1. **Evaluate** — Opus assesses the ticket. Rejects if too vague or complex, comments on Jira with the reason.
2. **Select projects** — Picks which repos from `projects:` are relevant to the ticket.
3. **Setup** — Clones/pulls only selected repos, creates feature branch `golem/SA-1111-slug`.
4. **Execute** — Agent works the ticket, committing as it goes with `[SA-1111]` prefix.
5. **Deliver** — Pushes branches, creates draft PRs on Bitbucket, comments PR links on Jira, transitions the ticket to `jira.done_transition`.

## Iterating on reviewer feedback

After a human reviews a Golem-opened PR, drive another pass with `mix golem.iterate <ticket | pr-path | pr-url>`. Pipeline:

1. **Resolve PR** — ticket key searches every configured repo for an open PR with a `golem/<KEY>-…` branch; a `ws/repo/id` triple or full URL fetches directly.
2. **Fetch feedback** — unresolved comments (non-bot authors, top-level threads) **and** unresolved Bitbucket PR tasks. Tasks are formalized action items and are framed as binding in the agent prompt; comments are weighted by type (suggestion / question / nit).
3. **Worktree** — checks out the PR's existing source branch (no new branch). Reuses the `tasks/<key>/<repo>` layout via `setup_iterate_worktree/4`.
4. **Run** — agent works through the feedback, commits each fix.
5. **Reply** — pushes the branch back, posts `Addressed in <sha>` once per parent thread (deduped across comments and tasks that share a parent). Tasks with no parent comment get a top-level PR comment. **Doesn't auto-resolve** — that's the reviewer's call.

Bare `mix golem.iterate` lists every open bot PR with unresolved-item counts (comments + tasks); informative, not active.

## Git Worktrees (Concurrent Tasks)

When running Jira tasks, golem uses git worktrees so multiple tasks can run simultaneously in the same container:

```
/home/agent/repos/api          ← persistent main clone (always on default branch)
/home/agent/repos/app          ← persistent main clone

/home/agent/tasks/SA-1111/api  ← worktree for SA-1111
/home/agent/tasks/SA-1111/app  ← worktree for SA-1111

/home/agent/tasks/SA-2222/api  ← worktree for SA-2222 (runs concurrently)
/home/agent/tasks/SA-2222/app  ← worktree for SA-2222
```

- Main clones in `/repos/` are created once and reused (only `git fetch` on subsequent runs)
- Each task gets isolated worktrees via `git worktree add` — separate working directories, shared `.git`
- Setup steps run per-worktree (each task gets its own `vendor/`, `node_modules/`, `.env`)
- Worktrees can be cleaned up after completion with `Golem.ProjectSetup.cleanup_worktrees(ticket_key)`
- `mix golem.setup` still clones directly to project `path` for testing (does not use worktrees)
