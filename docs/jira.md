# Jira & Bitbucket Workflow

## Configuration

Jira settings live under the `jira:` block in `.golem/config.yaml`:

```yaml
jira:
  base_url: https://yoursite.atlassian.net
  done_transition: "Pull Request / Deployable"   # optional, default "Done"
  comment_on_ticket: true                        # optional, default true
```

Setting `comment_on_ticket: false` silences all five Jira comment paths — evaluation reject, success (with PR links), agent self-reject, paused (step/budget cap), and unexpected error. Useful when you want Golem to push PRs but leave the ticket activity stream alone. PR creation and the `done_transition` are unaffected.

## Run a ticket

Run a ticket with `mix golem.run --jira PROJ-123`. The pipeline:

1. **Evaluate** — Opus assesses the ticket. Rejects if too vague or complex, comments on Jira with the reason.
2. **Select projects** — Picks which repos from `projects:` are relevant to the ticket.
3. **Setup** — Clones/pulls only selected repos, creates feature branch `golem/PROJ-123-slug`.
4. **Execute** — Agent works the ticket, committing as it goes with `[PROJ-123]` prefix.
5. **Deliver** — Pushes branches, creates draft PRs on Bitbucket, comments PR links on Jira, transitions the ticket to `jira.done_transition`.

### Nudging interpretation

When a ticket offers multiple approaches or is genuinely ambiguous, pass `--nudge` (alias `-n`) to steer the run without editing the ticket itself:

```bash
mix golem.run --jira PROJ-123 --nudge "go with approach 2 from the description"
mix golem.run --jira PROJ-123 -n "use the Phoenix LiveView pattern, not the Vue one"
```

The note is shown to the pre-flight evaluator and injected as an **Operator note** section near the top of the agent's goal — flagged as overriding any conflicting interpretation. It's per-run and not recorded on the ticket; for decisions that should be visible to teammates, leave a Jira comment instead.

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

/home/agent/tasks/PROJ-123/api  ← worktree for PROJ-123
/home/agent/tasks/PROJ-123/app  ← worktree for PROJ-123

/home/agent/tasks/PROJ-789/api  ← worktree for PROJ-789 (runs concurrently)
/home/agent/tasks/PROJ-789/app  ← worktree for PROJ-789
```

- Main clones in `/repos/` are created once and reused (only `git fetch` on subsequent runs)
- Each task gets isolated worktrees via `git worktree add` — separate working directories, shared `.git`
- Setup steps run per-worktree (each task gets its own `vendor/`, `node_modules/`, `.env`)
- Worktrees can be cleaned up after completion with `Golem.ProjectSetup.cleanup_worktrees(ticket_key)`
- `mix golem.setup` still clones directly to project `path` for testing (does not use worktrees)
