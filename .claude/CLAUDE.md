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

## Environment Variables

Set in `.env` (loaded by dotenv):
- `ANTHROPIC_API_KEY` — Required
- `PERPLEXITY_API_KEY` — Required for web_search
- `DISCORD_TOKEN` — Required for ask_user tool
- `DISCORD_CHANNEL_ID` — Required for ask_user tool

## Git Access (optional)

To let the bot push/pull from GitHub or Bitbucket, generate a dedicated SSH key:

```bash
mkdir -p ssh
ssh-keygen -t ed25519 -f ssh/id_ed25519 -N "" -C "golem-bot"
```

Then add the public key (`ssh/id_ed25519.pub`) to your GitHub/Bitbucket account. The `ssh/` directory is gitignored — keys stay local.

Optionally set git identity in `.env`:
```bash
GIT_USER="Your Name"
GIT_EMAIL=you@example.com
```

Recreate the container after setup: `podman rm -f golem-vm && ./containers/start.sh`

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
