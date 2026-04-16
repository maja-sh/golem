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
- [x] Git worktree support for concurrent ticket work
- [x] Ticket status transitions (move to configurable "Done" status)
- [x] Per-project setup steps with user support
- [x] Multi-turn planner with read-only tools (Sonnet explores, Opus plans)
- [x] MCP server support (stdio + HTTP transports)
- [x] `--force` flag to skip ticket evaluation
- [x] `--model` and `--budget` CLI flags
- [x] Push branches and create PRs on both success and failure
- [x] Read-before-write and compile-after-write enforcement in prompts
- [x] Sub-agent context enrichment (auto-include directory listings)
- [x] AGENTS.md/CLAUDE.md auto-discovery during planning and execution
- [x] Jira comments and labels in agent prompts
- [x] Per-project `instructions` field in projects.yml

## High Priority

### Prompt cache breakpoints on messages
The planner and executor send growing conversation history without cache markers. Adding `cache_control` to the last 1-2 messages before each API call could cut input costs by 80-90%. The system prompt is already cached but messages are not.

### Smarter context compaction in planner
After reading 20 files, the planner sends all of them every turn. Could summarize older file reads into a compact digest to reduce token usage.

### Incremental test execution
The agent writes multiple files then tests at the end. Should run the relevant test after each file change. Added to the prompt but could be enforced in code by auto-running a test command after `write_file`.

### Auto-commit safety net
Auto-commit every N steps so work is never lost when the agent gets stuck in loops or hits budget limits.

## Medium Priority

### Parallel task execution
Git worktrees are built but there's no CLI to run multiple Jira tickets concurrently (`mix golem.run --jira SA-1111,SA-2222`). Would need concurrent Runner processes sharing the same container.

### Webhook mode
Trigger runs from Jira webhooks (ticket moved to "Ready for Dev" → auto-start). No manual CLI needed. Could use a simple Phoenix endpoint or a polling approach.

### Run dashboard
Web UI showing active runs, cost, progress. Phoenix LiveView would be natural in Elixir.

### Smarter sub-agent delegation
Track which sub-agent goals have been completed and prevent re-delegation of the same task after verification rejection.

### GitHub Support
- GitHub API client (create PRs, post comments)
- Alternative to Bitbucket in project config (e.g. `git_host: github`)
- GitHub app token or PAT auth

### Safety
- Error rate circuit breaker: >50% errors in last 10 steps → pause

## Distribution

### Package as distributable CLI
- Use `mix release` to produce a self-contained Erlang release (bundles ERTS, no Elixir needed on target)
- GitHub Actions CI/CD matrix builds for linux-amd64, linux-arm64, darwin-arm64
- Upload tarballs to GitHub Releases, install via curl one-liner
- The `bin/golem` script from mix release becomes the CLI entrypoint
- Burrito (single binary) as a possible future enhancement

### CLI interface
```
golem --jira SA-1111
golem --task "inline prompt"
golem --file path-to-markdown.md
```

### Config migration
- Move `.golem/` to `~/.config/golem/` (respect `XDG_CONFIG_HOME`)
- Keep `.golem/` in project directory as per-project override
- Lookup order: project `.golem/` → `~/.config/golem/`
