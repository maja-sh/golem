# Golem

Autonomous agent that takes a goal, plans with Claude Opus, and executes with Claude Sonnet inside a sandboxed podman container.

## Quick Start

```bash
# One-time setup
cp .golem/config.example.yml .golem/config.yml   # then edit
cp .env.example .env                              # set ANTHROPIC_API_KEY
mix golem.doctor                                  # validate config + runtime

# Run a scenario (container auto-provisions on first run)
mix golem.run --scenario smoke_maze

# Run with a custom goal
mix golem.run "Build a REST API in Python"

# Resume a paused run
mix golem.resume --list
mix golem.resume <run_id>

# Export files from container
mix golem.export /home/agent/product ./output/product

# Test project setup (clone repos, no agent run)
mix golem.setup

# Run a Jira ticket
mix golem.run --jira SA-1111

# Run with visual browser verification
mix golem.run --jira SA-1111 --visual

# Skip evaluation, set budget, use specific model
mix golem.run --jira SA-1111 --force --budget 30 --model claude-opus-4-20250514

# Iterate on a PR — apply reviewer feedback, push back to same branch
mix golem.iterate SA-1111                             # by ticket key
mix golem.iterate hrdl/api/3480                       # by ws/repo/id
mix golem.iterate                                     # list open bot PRs
```

## Architecture

```
Goal → Opus (plan) → Sonnet (execute in loop) → Done
                         ↓
                    podman container (shell, files, GUI)
```

- **Runner** (`lib/golem/runner.ex`) — Main loop. Plans with Opus, executes with Sonnet, handles re-planning, multi-tool turns, context compaction, state persistence.
- **Claude** (`lib/golem/claude.ex`) — API client with prompt caching, extended thinking, exponential backoff retry.
- **Sandbox** (`lib/golem/sandbox.ex`) — GenServer wrapping `podman exec` with sentinel-based output parsing.
- **Tools** (`lib/golem/tools.ex`) — Tool definitions for Claude's tool use API. `for_depth/1` controls sub-agent nesting.
- **ToolHandler** (`lib/golem/tool_handler.ex`) — Dispatches tool calls to implementations.
- **Prompt** (`lib/golem/prompt.ex`) — System prompts for executor, planner, and sub-agents.
- **State** (`lib/golem/state.ex`) — Save/load run state for resume support.
- **Screenshot** (`lib/golem/screenshot.ex`) — Captures Xvfb display, saves to host, returns base64 for Claude.
- **Web** (`lib/golem/web.ex`) — Perplexity search and URL fetching.

## Tools (16)

shell, write_file, read_file, edit_file, list_directory, glob, grep, web_search, web_fetch, screenshot, gui_click, gui_type, gui_key, gui_scroll, sub_agent, think, done

## Key Design Decisions

- **Dual model**: Opus plans, Sonnet executes. `think(request_replan: true)` triggers Opus re-plan.
- **Multi-tool turns**: All tool_use blocks in a response are executed, not just the first.
- **Context compaction**: Old messages are summarized into a structured recap at 40 messages instead of being dropped.
- **State persistence**: Saved every 10 steps and on max_steps. Resume with `Golem.resume(id)`.
- **Sub-agents**: Isolated context, 50-step cap, depth capped at 3.
- **Container**: Agent runs as root. Xvfb on :99 for GUI. Volume `golem-data` for persistence.
- **Git worktrees**: Main clones in `/repos/`, per-task worktrees in `/tasks/{ticket}/`. Enables concurrent task execution.

## Config

User-facing config lives in `.golem/config.yml` (see `.golem/config.example.yml` for the template). `Golem.Config.load/0` runs at application boot and merges three layers in precedence order: `GOLEM_*` env vars → `.golem/config.yml` → built-in defaults in `Golem.Application.ensure_defaults/0`.

Run `mix golem.config` to print the resolved values and their source.

Top-level YAML keys:

```yaml
models:
  planner: claude-opus-4-7       # GOLEM_PLANNER_MODEL
  executor: claude-sonnet-4-6    # GOLEM_EXECUTOR_MODEL
  compaction: claude-sonnet-4-6  # GOLEM_COMPACTION_MODEL (optional, falls back to executor)

limits:
  max_steps: 200                 # GOLEM_MAX_STEPS
  max_cost: 10.0                 # GOLEM_MAX_COST
  thinking_budget: 10000         # GOLEM_THINKING_BUDGET
  command_timeout: 900000        # GOLEM_COMMAND_TIMEOUT
  stall_timeout: 120000          # GOLEM_STALL_TIMEOUT
  planner_max_tokens: 16000      # GOLEM_PLANNER_MAX_TOKENS
  planner_max_steps: 75          # GOLEM_PLANNER_MAX_STEPS
  executor_max_tokens: 16000     # GOLEM_EXECUTOR_MAX_TOKENS

container:
  name: golem-vm                 # GOLEM_CONTAINER
  user: agent                    # GOLEM_CONTAINER_USER
```

Adding a new setting: append a row to `@settings` in `lib/golem/config.ex` (yaml path + env var + type) and add a hard-coded default in `Golem.Application.ensure_defaults/0`. Document the new key in both `README.md` and this file (see "Documentation Rules" below).

## Project Config

Project setup lives under the `projects:` block in `.golem/config.yml`:

```yaml
bitbucket:
  workspace: hrdl

default_branch: master   # fallback for all projects

projects:
  - repo: hrdl/api
    path: /home/agent/api
    description: "Laravel JSON API"
    branch_from: main             # per-project override
    setup:
      - label: "install deps"
        run: "apt-get install -y php8.4"
      - label: "composer install"
        run: "composer install --no-interaction"
        user: agent
```

### Top-level fields

| Field | Required | Description |
|---|---|---|
| `bitbucket.workspace` | yes | Bitbucket workspace slug |
| `default_branch` | no | Fallback base branch for all projects (default: `main`) |

### Project fields

| Field | Required | Description |
|---|---|---|
| `repo` | yes | Bitbucket repo path (e.g. `hrdl/api`) |
| `path` | yes | Absolute path in the container where the repo is cloned |
| `description` | no | Human-readable project description, included in agent prompts |
| `branch_from` | no | Base branch for this project (overrides `default_branch`) |
| `setup` | no | List of setup steps to run after cloning (see below) |
| `instructions` | no | Golem-specific instructions injected into the agent prompt. Use for verification steps, testing requirements, or project-specific workflows that don't belong in the repo's AGENTS.md |
| `cache` | no | List of directories to copy from main clone to worktree before setup (e.g. `[node_modules, vendor]`). Speeds up dependency installs. |

### Setup step fields

| Field | Required | Description |
|---|---|---|
| `label` | yes | Display name shown in the TUI during setup |
| `run` | yes | Shell command to execute. Auto-`cd`s into the project's `path` before running |
| `user` | no | Run as this user (e.g. `agent`). Omit to run as root |

Setup steps without `user:` run as root (for system installs like `apt-get`). Steps with `user: agent` run as the container user (for project-level commands like `composer install`). Each `mix golem.setup` does a clean clone (removes existing dir first).

Test the setup with `mix golem.setup` — clones all repos into the container and runs setup scripts.

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

## Jira Integration

Jira settings live under the `jira:` block in `.golem/config.yml`:

```yaml
jira:
  base_url: https://yoursite.atlassian.net
  done_transition: "Pull Request / Deployable"   # optional, default "Done"
```

Run a ticket with `mix golem.run --jira SA-1111`. The pipeline:

1. **Evaluate** — Opus assesses the ticket. Rejects if too vague or complex, comments on Jira with the reason.
2. **Select projects** — Picks which repos from `projects:` are relevant to the ticket.
3. **Setup** — Clones/pulls only selected repos, creates feature branch `golem/SA-1111-slug`.
4. **Execute** — Agent works the ticket, committing as it goes with `[SA-1111]` prefix.
5. **Deliver** — Pushes branches, creates draft PRs on Bitbucket, comments PR links on Jira, transitions the ticket to `jira.done_transition`.

### Iterating on reviewer feedback

After a human reviews a Golem-opened PR, drive another pass with `mix golem.iterate <ticket | pr-path | pr-url>`. Pipeline:

1. **Resolve PR** — ticket key searches every configured repo for an open PR with a `golem/<KEY>-…` branch; a `ws/repo/id` triple or full URL fetches directly.
2. **Fetch feedback** — unresolved comments (non-bot authors, top-level threads) **and** unresolved Bitbucket PR tasks. Tasks are formalized action items and are framed as binding in the agent prompt; comments are weighted by type (suggestion / question / nit).
3. **Worktree** — checks out the PR's existing source branch (no new branch). Reuses the `tasks/<key>/<repo>` layout via `setup_iterate_worktree/4`.
4. **Run** — agent works through the feedback, commits each fix.
5. **Reply** — pushes the branch back, posts `Addressed in <sha>` once per parent thread (deduped across comments and tasks that share a parent). Tasks with no parent comment get a top-level PR comment. **Doesn't auto-resolve** — that's the reviewer's call.

Bare `mix golem.iterate` lists every open bot PR with unresolved-item counts (comments + tasks); informative, not active.

## MCP Servers

External tool servers are configured under the `mcp:` block in `.golem/config.yml`:

### stdio transport (local subprocess)

```yaml
mcp:
  servers:
    - name: elastic
      command: npx
      args: ["-y", "@elastic/mcp-server-elasticsearch"]
      env:
        ELASTICSEARCH_URL: "https://your-cluster.es.io"
        ELASTICSEARCH_API_KEY: "your-key"
```

### HTTP transport (remote server)

```yaml
mcp:
  servers:
    - name: remote-tools
      url: "http://localhost:3000/mcp"
      headers:
        Authorization: "Bearer your-token"
```

### Server fields

| Field | Required | Description |
|---|---|---|
| `name` | yes | Server identifier. Tools are namespaced as `mcp_{name}_{tool}` |
| `command` | stdio | Executable to spawn (must be in PATH) |
| `args` | no | Command-line arguments (stdio only) |
| `env` | no | Environment variables (stdio only) |
| `url` | http | URL of the MCP HTTP endpoint |
| `headers` | no | HTTP headers (e.g. auth tokens, http only) |

Use `command` for stdio or `url` for HTTP — not both. MCP tools are available to both the planner (for research) and executor (for runtime checks). Check status with `mix golem.mcp`.

## Environment Variables

Set in `.env` (loaded by dotenv):

| Variable | Required | Description | Scopes / Notes |
|---|---|---|---|
| `ANTHROPIC_API_KEY` | yes | Claude API key | — |
| `PERPLEXITY_API_KEY` | for web_search | Perplexity search API key | — |
| `DISCORD_TOKEN` | for ask_user | Discord bot token | Send Messages, Read Message History |
| `DISCORD_CHANNEL_ID` | for ask_user | Discord channel for ask_user | — |
| `JIRA_EMAIL` | for Jira | Atlassian account email | Shared with Bitbucket basic auth |
| `JIRA_API_TOKEN` | for Jira | Atlassian API token | `read:jira-work`, `write:jira-work` (read issues, post comments) |
| `BITBUCKET_API_TOKEN` | for Bitbucket | Bitbucket app password | `Repositories: Read`, `Repositories: Write`, `Pull requests: Write` (clone, push, create PRs) |
| `GIT_USER` | no | Git author name in container | Defaults to "Golem Bot" |
| `GIT_EMAIL` | no | Git author email in container | Defaults to "golem@bot.local" |

## System Dependencies

- `podman` — Container runtime (required)
- `bat` — Syntax highlighting in diffs (optional, falls back to plain text). Install: `brew install bat`

## Scenarios

Test scenarios in `scenarios/`. Run with `--scenario <name>`:
- `smoke_maze` — Basic smoke test (3-5 steps)
- `cli_sitemap` — Medium CLI tool build (30-40 steps)
- `rest_api_bookmarks` — Complex API build (20-40 steps)
- `gui_snake` — GUI rendering test
- `money_maker` — Full research → plan → build cycle (150-300 steps)

## Per-run event log

Every non-trivial thing that happens during a run is appended as a JSON line to `runs/<run_id>/events.jsonl`. The emitter lives in `lib/golem/events.ex` and is called from `runner.ex` + `tool_handler.ex`. The file is the canonical record for post-mortem analysis and replay.

Event shape:

```json
{"ts":"2026-04-17T15:30:12.345Z","type":"tool_call","step":12,"depth":0,"payload":{"name":"shell","input":{"command":"..."},"tool_use_id":"..."}}
```

`step` and `depth` are hoisted to top-level when the caller provides them, so `jq '.[] | select(.step > 50)'` works without digging into `.payload`.

Event types emitted today:

| Type | Emitted from | Notes |
|---|---|---|
| `run_start` / `run_end` / `run_paused` / `run_resumed` / `run_error` | runner `run/2`, `resume/2` | Lifecycle markers |
| `step` | runner `do_loop/1` | One per main-loop iteration |
| `api_call` | runner after `Golem.Claude.call` | Model, elapsed ms, token usage, cache counts |
| `agent_text` | runner, when the model produces prose | |
| `tool_call` / `tool_result` | runner `execute_single_tool/4` + concurrent batch | Every invocation, including retries |
| `thought` | `Golem.ToolHandler.execute/2` for `think` | `request_replan` flag included |
| `sub_agent_start` / `sub_agent_end` / `sub_agent_skipped` | runner `run_sub_agent/4`, tool_handler dedup | |
| `plan_created` | runner after `create_plan/2` | Plan text + phase/step counts |
| `replan_start` / `replan_done` | runner `handle_replan/5` | |
| `compaction` | runner `snip_messages/1` + `do_trim_messages/1` | Reports type: `snip` or `full` |
| `stuck` / `think_loop` / `drift` / `drift_check` / `staleness_nudge` / `file_size_warning` | runner warning injectors | |
| `verify_start` / `verify_done` | runner `maybe_verify/2` | Adversarial verifier gate |
| `no_tool_response` | runner | Agent returned text with no tool call |
| `agents_md_discovered` | runner planner | |

Prose logging in `logs/golem.log` is intentionally sparse — only `Logger.warning` / `Logger.error` fire there. For anything per-step, read the events file.

Reading back:

```bash
jq . runs/<id>/events.jsonl | less
jq 'select(.type == "tool_call") | .payload.name' runs/<id>/events.jsonl | sort | uniq -c
jq 'select(.type == "api_call") | [.step, .payload.elapsed_ms, .payload.input_tokens]' runs/<id>/events.jsonl
```

Or from Elixir: `Golem.Events.read(run_id)` returns a list of decoded maps.

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

## Documentation Rules

- When adding or changing config schema (any top-level key in `.golem/config.yml`), environment variables, or CLI flags, always update **both** this file and `README.md`.
- `README.md` is the human-readable reference. Keep it in sync with this file.

## Conventions

- Elixir 1.19, OTP 27
- Uses podman (not docker)
- Container image: `golem-vm:latest`
- Container name: `golem-vm`
- Logs: `logs/golem.log`
- Screenshots: `screenshots/`
- Run state: `runs/<id>/state.json`
