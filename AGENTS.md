# Golem

Autonomous agent that takes a goal, plans with Claude Opus, and executes with Claude Sonnet inside a sandboxed podman container.

## Quick Start

```bash
# One-time setup
cp .golem/config.example.yaml .golem/config.yaml   # then edit
cp .env.example .env                              # set ANTHROPIC_API_KEY
mix golem.doctor                                  # validate config + runtime

# Run a scenario or custom goal
mix golem.run --scenario smoke_maze
mix golem.run "Build a REST API in Python"

# Resume a paused run
mix golem.resume --list
mix golem.resume <run_id>

# Run a Jira ticket
mix golem.run --jira PROJ-123
mix golem.run --jira PROJ-123 --visual
mix golem.run --jira PROJ-123 --nudge "go with approach 2 from the description"
mix golem.run --jira PROJ-123 --force --budget 30 --model claude-opus-4-20250514

# Iterate on reviewer feedback
mix golem.iterate PROJ-123
mix golem.iterate your-workspace/api/42
mix golem.iterate                  # list open bot PRs

# Other utilities
mix golem.setup                                       # test project setup
mix golem.export /home/agent/product ./output/product # export files from container
```

`README.md` is the human-readable command reference.

## Architecture

```
Goal → Opus (plan) → Sonnet (execute in loop) → Done
                         ↓
                    podman container (shell, files, GUI)
```

- **Runner** (`lib/golem/runner.ex`) — Main loop. Plans with Opus, executes with Sonnet, handles re-planning, multi-tool turns, context compaction, state persistence.
- **LLM** (`lib/golem/llm.ex`) — Provider-agnostic facade. Dispatches to `Golem.Provider` implementations based on the `provider:` opt or role config.
- **Claude** (`lib/golem/claude.ex`) — Anthropic provider. Prompt caching, extended thinking, 1M-context beta, exponential backoff retry. Implements `Golem.Provider`.
- **OpenRouter** (`lib/golem/openrouter.ex`) — OpenAI-compatible provider for Qwen / DeepSeek / Llama / etc. Translates the Anthropic-flavored message + tool shapes both ways. No extended thinking, no prompt caching.
- **Pricing** (`lib/golem/pricing.ex`) — Per-model `$/million tokens` lookup. Chain: explicit `pricing:` config override → built-in Anthropic defaults → OpenRouter `/api/v1/models` (fetched once, cached an hour) → zero + one-time warning. Provider detected from the model-name shape (`claude-*` → Anthropic, `vendor/model` → OpenRouter).
- **Sandbox** (`lib/golem/sandbox.ex`) — GenServer wrapping `podman exec` with sentinel-based output parsing.
- **Tools** (`lib/golem/tools.ex`) — Tool definitions for Claude's tool use API. `for_depth/1` controls sub-agent nesting.
- **ToolHandler** (`lib/golem/tool_handler.ex`) — Dispatches tool calls to implementations.
- **Prompt** (`lib/golem/prompt.ex`) — System prompts for executor, planner, and sub-agents.
- **State** (`lib/golem/state.ex`) — Save/load run state for resume support.
- **Screenshot** (`lib/golem/screenshot.ex`) — Captures Xvfb display, saves to host, returns base64 for Claude.
- **Web** (`lib/golem/web.ex`) — Perplexity search and URL fetching.
- **TUI** (`lib/golem/tui.ex`) — Terminal UI. Builds the Golem-specific status block (forge verbs, tool icons, progress checklist, batch + retry sections) and delegates pinned-area rendering to `pinned_status`.
- **PinnedStatus** (`pinned_status/`) — Sibling package. Diff-rendered pinned status block: only the lines that actually change emit bytes, so the spinner ticking doesn't flicker or rewrite the checklist. Scriptable via `PinnedStatus.Scenario` + `mix pinned_status.demo`. Designed to be lifted out of the repo if it's worth open-sourcing.

## Tools (16)

shell, write_file, read_file, edit_file, list_directory, glob, grep, web_search, web_fetch, screenshot, gui_click, gui_type, gui_key, gui_scroll, sub_agent, think, done

## Key Design Decisions

- **Dual model**: Opus plans, Sonnet executes. `think(request_replan: true)` triggers Opus re-plan. Each role's provider is independently configurable — e.g. Opus for planning via Anthropic, Qwen for execution via OpenRouter.
- **Multi-tool turns**: All tool_use blocks in a response are executed, not just the first.
- **Context compaction**: Old messages are summarized into a structured recap only when the estimated token count gets within 15K of the configured `limits.context_window` (default 200K). Setting `context_window` above 200K automatically enables Anthropic's 1M-context beta (2× pricing above 200K). Microcompaction (clearing tool_results from old messages) is intentionally absent — it caused re-read loops where the agent would summarize a file then re-read it because the verbatim content was gone.
- **State persistence**: Saved every 10 steps and on max_steps. Resume with `Golem.resume(id)`.
- **Sub-agents**: Isolated context, 50-step cap, depth capped at 3.
- **Container**: Agent runs as root. Xvfb on :99 for GUI. Volume `golem-data` for persistence.
- **Git worktrees**: Main clones in `/repos/`, per-task worktrees in `/tasks/{ticket}/`. Enables concurrent task execution.

## Config

User-facing config lives in `.golem/config.yaml` (see `.golem/config.example.yaml` for the template). `Golem.Config.load/0` runs at boot and merges three layers in precedence order: `GOLEM_*` env vars → `.golem/config.yaml` → built-in defaults in `Golem.Application.ensure_defaults/0`. Run `mix golem.config` to print the resolved values and their source.

Top-level YAML keys: `models`, `limits`, `container`, `bitbucket`, `default_branch`, `projects`, `jira`, `mcp`. See [docs/config.md](docs/config.md) for the full schema, project setup, MCP servers, and environment variables.

Adding a new setting: append a row to `@settings` in `lib/golem/config.ex` (yaml path + env var + type) and add a hard-coded default in `Golem.Application.ensure_defaults/0`. Document the new key in both `README.md` and this file (see "Documentation Rules" below).

## Jira & Bitbucket Workflow

`mix golem.run --jira PROJ-123` evaluates the ticket, picks relevant repos, sets up worktrees, executes, and pushes a draft PR. `mix golem.iterate <ticket | pr-path | pr-url>` applies reviewer feedback to an existing bot PR.

See [docs/jira.md](docs/jira.md) for the full pipeline, worktree layout, and iterate flow.

## Per-run event log

Every non-trivial event during a run is appended as a JSON line to `runs/<run_id>/events.jsonl` (emitted from `lib/golem/events.ex`, called by `runner.ex` and `tool_handler.ex`). It is the canonical record for post-mortem analysis and replay — prose logging in `logs/golem.log` is sparse by design.

Read with `jq` or `Golem.Events.read(run_id)`. See [docs/events.md](docs/events.md) for the event shape and the full type catalog.

## Tests

```bash
mix test                 # default suite — excludes :e2e tags
mix test.e2e             # only end-to-end tests (hit the real Claude API)
mix test --include e2e   # full suite including e2e
```

- `test/` — unit tests, all pure functions. No network or container.
- `test/runner/` — tests for the extracted `Golem.Runner.*` modules (compaction, triggers, reminder).
- `test/e2e/` — end-to-end tests tagged `@tag :e2e`. Excluded from the default run via `ExUnit.start(exclude: [:e2e])` in `test/test_helper.exs`. Require `ANTHROPIC_API_KEY` and make real API calls — they cost money and are slow.

When adding a new e2e test, tag the module with `@moduletag :e2e`. Keep the scenarios minimal — a single round-trip is enough to verify the integration. Expensive multi-step runs belong in `scenarios/` invoked via `mix golem.run`, not the test suite.

## Scenarios

Test scenarios in `scenarios/`. Run with `--scenario <name>`:
- `smoke_maze` — Basic smoke test (3-5 steps)
- `cli_sitemap` — Medium CLI tool build (30-40 steps)
- `rest_api_bookmarks` — Complex API build (20-40 steps)
- `gui_snake` — GUI rendering test

## Documentation Rules

- When adding or changing config schema (any top-level key in `.golem/config.yaml`), environment variables, or CLI flags, always update **both** this file and `README.md`. If detail belongs in `docs/config.md` or `docs/jira.md`, update that file as the source of truth and link from here.
- `README.md` is the human-readable reference. Keep it in sync with this file.
- `CLAUDE.md` and `GEMINI.md` are symlinks to `AGENTS.md` — edit `AGENTS.md` only.

## Commit messages

Never add agent-attribution trailers to commit messages — no `Co-Authored-By: Claude`, no `Generated with Claude Code`, no equivalent line for any other agent (Gemini, Codex, etc.). Write the commit as if a human authored it.

## Conventions

- Elixir 1.19, OTP 27
- Uses podman (not docker)
- Container image: `localhost/golem-vm:latest`
- Container name: `golem-vm`
- Logs: `logs/golem.log`
- Screenshots: `screenshots/`
- Run state: `runs/<id>/state.json`
