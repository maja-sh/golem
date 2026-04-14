# TODO

## Done

- [x] Jira API client (fetch tickets, post comments, scoped API tokens)
- [x] Bitbucket API client (create draft PRs, scoped API tokens)
- [x] Project setup (clone/pull repos, create branches, run setup scripts)
- [x] Ticket evaluation (Opus pre-flight, accept/reject with Jira comment)
- [x] Dynamic project selection (evaluator picks relevant repos)
- [x] Commit-during-work (agent commits as it goes, orchestrator pushes)
- [x] `mix golem.run --jira SA-1111` CLI entry point
- [x] `mix golem.setup` test project setup without running agent
- [x] Split config: `.golem/projects.yml` (general) + `.golem/jira.yml` (Jira-specific)
- [x] Shell stall detection (120s no-output timeout)
- [x] Per-item progress verification (planner verify commands)

## Pending

### GitHub Support
- GitHub API client (create PRs, post comments)
- Alternative to Bitbucket in project config (e.g. `git_host: github`)
- GitHub app token or PAT auth
- Clone URL format for GitHub (`https://x-access-token:{token}@github.com/...`)

### Safety
- Per-ticket cost cap (default $20) — pause + notify
- Error rate circuit breaker: >50% errors in last 10 steps → pause

### Jira Enhancements
- Ticket status transitions (move to "In Progress" / "Done")
- PR reviewer assignment
- Discord trigger: `jira SA-1111` command in daemon mode

### Multi-ticket
- Git worktree support for concurrent ticket work
- Shared build cache across worktrees
