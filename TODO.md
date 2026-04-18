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
- [x] Prompt cache breakpoints on messages (90% input cost reduction)
- [x] Sub-agent deduplication (prevent re-running completed goals)
- [x] File cache invalidation after sub-agent runs
- [x] Per-step verification enforcement in prompts
- [x] Ticket type and priority in agent goal
- [x] Generic secrets/file mounting (container.mounts + container.env in .golem/config.yml)
- [x] Auto-provision container on boot (no manual `./containers/start.sh`)
- [x] Per-run event log (`runs/<id>/events.jsonl`)
- [x] Unified `.golem/config.yml` — rolls up projects.yml, jira.yml, mcp.yml under one file

## High Priority

### Agent-initiated Discord questions (`ask_user` overhaul)
Let the agent ping the operator on Discord when a ticket genuinely needs human judgment, rather than guessing or aborting. Opt-in via a Jira label (`ask-human`) that injects "use ask_user for significant decisions" into the prompt. Add a timeout, per-run question budget (max 3), `--no-ask` flag, TUI "awaiting reply" indicator, and `:ask_user` event. Full design in `DISCORD_COMMUNICATION.md`. Effort: ~2-3 hours for the minimal cut, half a day for everything.

### Zoom Team Chat backend for `ask_user`
Work switched from Slack to Zoom Chat, so the operator-reachable channel is Zoom, not Discord. Build a pluggable `ask_user` backend (`backend: discord | zoom`) and add a Zoom Chat implementation: register a Chatbot app in the Zoom Marketplace, handle incoming replies via webhook (or poll if we want to avoid a public endpoint), post via `chat_channels/{id}/messages`. Do this alongside the ask_user overhaul above so the interface is designed for multiple backends from the start.

### Auto-commit safety net
Auto-commit every N steps so work is never lost when the agent gets stuck in loops or hits budget limits.

### Prompt / context infrastructure (from `CLAUDE_PROMPT.md` research)
Things Claude Code does that Golem doesn't, ordered by impact. Full findings and citations in `CLAUDE_PROMPT.md` §11.4.

- **Token-based compaction threshold** instead of message count. Fire when `estimated_tokens + summary_buffer > window_size` so we compact before the model drowns in context. Covers the old "planner keeps sending 20 file-reads every turn" issue.
- **Per-tool-result cap with disk spill.** 50 KB per result, spill the rest to a file path the agent can Read on demand. Today a single large `cat` can poison context and cause loops because compaction then drops the tool result and the model re-runs the command.
- **Audit what survives compaction.** The compacted summary must list "commands already executed" explicitly — if it doesn't, the model has no memory it already ran them, which is a major loop cause.
- **Per-turn `<system-reminder>`** injecting current git status, last N commands (with short result hashes), remaining budget, active task. Cheap, cache-friendly, keeps the model grounded without growing history.
- **Longer tool descriptions** carrying behavioral rules ("don't re-run the same command if its result is in context"). Rules in the tool description are enforced when the model considers that tool; rules in the system prompt get crowded out.
- **Visible compaction boundary message** in the conversation so the model knows why it can no longer see earlier tool results.

### TUI rework (from `CLAUDE_TUI.md` research)
Claude Code's TUI tricks that would make Golem's TUI snappier and clearer. Full findings in `CLAUDE_TUI.md` §14.

- **Snappiness:** single animation clock (not overlapping `:timer`s), viewport-gated ticks, per-message height cache, buffer-cap before render (10 MB `cat` should never reach the view), `Process.send_after` per-event instead of polling intervals.
- **Clarity:** tool-specific formatters (short label + full args, never raw JSON), Unicode status glyphs for the todo list (`○` / `◐` / `●`), uniform status row format `<glyph> <verb> <subject> · <metadata>` with elapsed on in-progress items, 30 s TTL before completed tasks fade.
- **Sub-agents:** horizontal colored pills instead of nested indentation, distinct color per concurrent sub-agent, spinner follows focus (unfocused agents blink their pill for activity).
- **Streaming:** paint assistant text chunk-by-chunk, minimum 2 s thinking-block visibility so short thinks don't flicker, progress sub-messages indented under long-running tools.
- **Architecture:** centralized state with selector-based subscriptions (GenServer emits `{:field_changed, name, value}`), tool registry owns rendering (`user_facing_name` + `render_args` callbacks), tools explicitly emit `:started|:progress|:completed|:failed` — the UI never infers status by diffing prior state.

## Medium Priority

### Parallel task execution
Git worktrees are built but there's no CLI to run multiple Jira tickets concurrently (`mix golem.run --jira SA-1111,SA-2222`). Would need concurrent Runner processes sharing the same container.

### Webhook mode
Trigger runs from Jira webhooks (ticket moved to "Ready for Dev" → auto-start). No manual CLI needed. Could use a simple Phoenix endpoint or a polling approach.

### Run dashboard
Web UI showing active runs, cost, progress. Phoenix LiveView would be natural in Elixir.

### Parallel project setup
Run project clone/setup in parallel during `mix golem.setup`. System-level steps (apt-get) run once sequentially, then per-project steps (composer, npm) run in parallel. Needs dynamic TUI to show per-project status updating in place. dpkg lock contention is the main constraint.

### GitHub Support
- GitHub API client (create PRs, post comments)
- Alternative to Bitbucket in project config (e.g. `git_host: github`)
- GitHub app token or PAT auth

### Safety
- Error rate circuit breaker: >50% errors in last 10 steps → pause

## Distribution

Ship `golem` as a self-contained executable users install with one command, configure via one file, and run from any project directory. No Elixir toolchain on target machines.

### Package as distributable CLI
- Use `mix release` to produce a self-contained Erlang release (bundles ERTS, no Elixir needed on target)
- GitHub Actions CI/CD matrix builds for linux-amd64, linux-arm64, darwin-arm64
- Upload tarballs to GitHub Releases, install via curl one-liner
- The `bin/golem` script from mix release becomes the CLI entrypoint
- Burrito (single binary) as a possible future enhancement

### CLI interface
```
golem setup                    # provision container, validate config
golem run --jira SA-1111
golem run --task "inline prompt"
golem run --file path-to-markdown.md
golem resume <run_id>
golem doctor                   # validate config + runtime health
golem config                   # print resolved config
golem mcp                      # list MCP server connectivity
golem events <run_id>          # tail / inspect events.jsonl
```

### `golem doctor` — config + health validator
Single command that reports every way the setup is wrong:
- YAML parses; unknown top-level keys warned
- `container.mounts[].src` paths exist (or soft-warn if `required: false`)
- Container image buildable / present; container reachable
- `projects[].path` looks reasonable; `setup[].run` non-empty
- `jira.base_url` reachable; `JIRA_API_TOKEN` + `JIRA_EMAIL` present
- MCP stdio servers resolve to executables; HTTP servers respond to `tools/list`
- `ANTHROPIC_API_KEY` present and valid (cheap call)

Emit machine-readable report (`--json`) for CI use.

### Config migration
- Move `.golem/` to `~/.config/golem/` (respect `XDG_CONFIG_HOME`)
- Keep `.golem/` in project directory as per-project override
- Lookup order: project `.golem/` → `~/.config/golem/`

### Ship the image, don't build it
- Push the base `golem-vm` image to GHCR / Docker Hub as part of CI
- `golem setup` pulls from registry instead of building locally (first-run takes 30s instead of 10 min)
- Keep Dockerfile in `priv/` for users who want to customize + build locally
