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

### Interactive setup wizard (`golem init`)
A guided onboarding command that prompts for each piece of config a teammate needs and writes `.env` + `.golem/config.yml` for them. Today the onboarding checklist in the README is hand-followed and easy to mis-step (wrong scopes on the Atlassian token, missing SSH key, forgotten Bitbucket workspace). Steps:

1. Detect podman/docker, prompt to install if missing.
2. Prompt for ANTHROPIC_API_KEY, ping the API to validate.
3. Prompt for Bitbucket workspace + ask if the user wants Jira integration; if yes, prompt for `JIRA_EMAIL`, `JIRA_API_TOKEN`, `BITBUCKET_API_TOKEN`, `jira.base_url`. Validate by hitting `/myself` on each API.
4. Generate `ssh/id_ed25519` if absent, print the public key + Bitbucket account-settings URL, wait for the user to confirm they've added it.
5. Walk through `projects:` interactively — paste a repo path (e.g. `hrdl/api`), prompt for container path + branch + setup commands.
6. Write `.env` (mode 0600) and `.golem/config.yml`. Run `golem doctor` at the end.

Effort: ~half a day for a serviceable version. Owl/IO.gets-based prompting is fine for v1.

### PR review loop — apply reviewer suggestions to an open PR
New CLI: `mix golem.run --pr hrdl/api/3480`. Most plumbing already exists (Bitbucket client, worktrees, commit + push flow); the missing piece is turning reviewer feedback into a goal and pushing back to the same branch.

Pipeline:
1. **Fetch comments.** `getPullRequestComments` + `getPullRequestTasks` from the Bitbucket MCP. Filter to unresolved threads not authored by the bot. Prioritize PR tasks (explicit action items) over free-floating comments. Parse Bitbucket ` ```suggestion ` blocks as first-class "apply exactly this" instructions.
2. **Assemble goal.** Single agent goal containing PR title/description + grouped reviewer comments with their `file:line` anchors and verbatim text. Tell the agent to apply concrete suggestions, explain-and-skip questions, and call `ask_user` for genuine ambiguity.
3. **Worktree on the existing PR branch.** Reuse `Golem.ProjectSetup.create_worktree` but check out the PR's branch (no new branch), worktree path like `/home/agent/tasks/pr-3480/api`.
4. **Run.** Normal runner loop with current budget/step limits.
5. **Push + reply.** Push the branch back (no force unless commits were rewritten — usually not). For each addressed thread, post `Addressed in <sha>` via `addPullRequestComment`. **Don't auto-resolve** — leave thread resolution to the human reviewer so they see what was done.

Non-obvious decisions:
- **Loop risk.** Reviewer → bot → reviewer → bot. Cap at N iterations per PR in the events log (bot checks history before running), or keep it manual-only (operator invokes per pass).
- **Suggestion blocks.** When reviewers use ` ```suggestion ` fenced blocks, apply them directly without the model's judgment — cheap, faithful, matches the reviewer's intent exactly.
- **Auth.** MVP is manual-trigger only, operator is the gate. Webhook/auto-trigger is deferred; would need per-PR allowlist and a budget cap.

Effort: ~half a day for MVP (comment fetching + goal assembly + reply-with-sha). Another half day for polish (suggestion-block parsing, `--dry-run`, resume support, iteration cap).

## Medium Priority

### Parallel task execution
Git worktrees are built but there's no CLI to run multiple Jira tickets concurrently (`mix golem.run --jira SA-1111,SA-2222`). Would need concurrent Runner processes sharing the same container.

### Webhook mode
Trigger runs from Jira webhooks (ticket moved to "Ready for Dev" → auto-start). No manual CLI needed. Could use a simple Phoenix endpoint or a polling approach.

### Run dashboard
Web UI showing active runs, cost, progress. Phoenix LiveView would be natural in Elixir.

### Parallel project setup
Run project clone/setup in parallel during `mix golem.setup`. System-level steps (apt-get) run once sequentially, then per-project steps (composer, npm) run in parallel. Needs dynamic TUI to show per-project status updating in place. dpkg lock contention is the main constraint.

### Multi-provider LLM support (OpenAI, custom models)
Today golem talks directly to the Anthropic API in `Golem.Claude`. Add a `Golem.LLM` behaviour with per-provider adapters so the executor and planner can run on OpenAI, Ollama/vLLM/LM Studio (OpenAI-compatible base_url), OpenRouter, etc. Provider chosen via config — either explicit (`provider: openai`) or inferred from model name.

Two adapters covers ~95% of what users want:
1. `Golem.LLM.Anthropic` — current Claude code, refactored.
2. `Golem.LLM.OpenAI` — OpenAI + any OpenAI-compatible endpoint via configurable `base_url`. Bedrock/Vertex/Gemini deferred until asked for.

Hard parts specific to golem:
- **Prompt caching is Anthropic-only and load-bearing.** ~90% input-token discount on cache hits today. OpenAI has implicit caching (smaller, no `cache_control` knob). Others have nothing. Cache-breakpoint logic in `Golem.Prompt` + `Golem.Runner.Compaction` becomes a no-op for non-Anthropic; design for that.
- **Tool-call format differs.** Anthropic's `tool_use`/`tool_result` blocks vs OpenAI's `tool_calls` + `role: "tool"`. Pick a canonical internal shape; adapters translate at the boundary so the runner never sees provider JSON.
- **Extended thinking is Opus-only.** `thinking_budget` becomes provider-aware; adapters honor or silently drop.
- **Tool fluency varies wildly.** Sonnet is reliable on read/edit/test loops; small open models often loop or fabricate args. Document "executor must be a tool-fluent model."

Config sketch:
```yaml
models:
  executor:
    provider: openai
    base_url: http://localhost:11434/v1    # ollama
    name: qwen2.5-coder:32b
```

Effort: ~2 days for the behaviour, Anthropic refactor, one OpenAI-compatible adapter (including tool-block translation + per-model pricing). Ongoing tax: every Anthropic-specific feature thereafter needs a no-op fallback path.

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
