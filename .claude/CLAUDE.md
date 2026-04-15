# Golem

Autonomous agent that takes a goal, plans with Claude Opus, and executes with Claude Sonnet inside a sandboxed podman container.

## Quick Start

```bash
# Build and start the container
podman build -t golem-vm:latest -f containers/Dockerfile containers/
./containers/start.sh

# Run a scenario
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

## Config

See `config/config.exs`. Key settings:
- `planner_model` / `executor_model` — Claude models
- `thinking_budget` — Extended thinking token budget
- `max_steps` — Default step limit
- `command_timeout` — Shell command timeout
- `stall_timeout` — Shell stall detection timeout (default 120s)

## Project Config

Project setup is configured in `.golem/projects.yml`:

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
        run: "apt-get install -y php8.4"       # runs as root
      - label: "composer install"
        run: "composer install --no-interaction" # auto-cds into project path
        user: agent                              # runs as container user
```

Setup steps auto-`cd` into the project's `path` before running. Steps without `user:` run as root (for system installs), steps with `user: agent` run as the container user (for project-level commands). Each `mix golem.setup` does a clean clone (removes existing dir first).

Test the setup with `mix golem.setup` — clones all repos into the container and runs setup scripts.

## Jira Integration

Jira settings live in `.golem/jira.yml`:

```yaml
jira:
  base_url: https://yoursite.atlassian.net
```

Run a ticket with `mix golem.run --jira SA-1111`. The pipeline:

1. **Evaluate** — Opus assesses the ticket. Rejects if too vague or complex, comments on Jira with the reason.
2. **Select projects** — Picks which repos from `projects.yml` are relevant to the ticket.
3. **Setup** — Clones/pulls only selected repos, creates feature branch `golem/SA-1111-slug`.
4. **Execute** — Agent works the ticket, committing as it goes with `[SA-1111]` prefix.
5. **Deliver** — Pushes branches, creates draft PRs on Bitbucket, comments PR links on Jira.

## Environment Variables

Set in `.env` (loaded by dotenv):
- `ANTHROPIC_API_KEY` — Required
- `PERPLEXITY_API_KEY` — Required for web_search
- `DISCORD_TOKEN` — Required for ask_user tool
- `DISCORD_CHANNEL_ID` — Required for ask_user tool
- `JIRA_EMAIL` — Required for Jira/Bitbucket (Atlassian account email)
- `JIRA_API_TOKEN` — Required for Jira (scoped API token)
- `BITBUCKET_API_TOKEN` — Required for Bitbucket push/PR (scoped API token)
- `GIT_USER` / `GIT_EMAIL` — Git identity for commits in container

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

## Conventions

- Elixir 1.19, OTP 27
- Uses podman (not docker)
- Container image: `golem-vm:latest`
- Container name: `golem-vm`
- Logs: `logs/golem.log`
- Screenshots: `screenshots/`
- Run state: `runs/<id>/state.json`
