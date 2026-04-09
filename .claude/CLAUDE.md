# Penbot

Autonomous agent that takes a goal, plans with Claude Opus, and executes with Claude Sonnet inside a sandboxed podman container.

## Quick Start

```bash
# Build and start the container
podman build -t penbot-vm:latest -f containers/Dockerfile containers/
./containers/start.sh

# Run a scenario
mix penbot.run --scenario smoke_maze

# Run with a custom goal
mix penbot.run "Build a REST API in Python"

# Resume a paused run
mix penbot.resume --list
mix penbot.resume <run_id>

# Export files from container
mix penbot.export /home/agent/product ./output/product
```

## Architecture

```
Goal → Opus (plan) → Sonnet (execute in loop) → Done
                         ↓
                    podman container (shell, files, GUI)
```

- **Runner** (`lib/penbot/runner.ex`) — Main loop. Plans with Opus, executes with Sonnet, handles re-planning, multi-tool turns, context compaction, state persistence.
- **Claude** (`lib/penbot/claude.ex`) — API client with prompt caching, extended thinking, exponential backoff retry.
- **Sandbox** (`lib/penbot/sandbox.ex`) — GenServer wrapping `podman exec` with sentinel-based output parsing.
- **Tools** (`lib/penbot/tools.ex`) — Tool definitions for Claude's tool use API. `for_depth/1` controls sub-agent nesting.
- **ToolHandler** (`lib/penbot/tool_handler.ex`) — Dispatches tool calls to implementations.
- **Prompt** (`lib/penbot/prompt.ex`) — System prompts for executor, planner, and sub-agents.
- **State** (`lib/penbot/state.ex`) — Save/load run state for resume support.
- **Screenshot** (`lib/penbot/screenshot.ex`) — Captures Xvfb display, saves to host, returns base64 for Claude.
- **Web** (`lib/penbot/web.ex`) — Perplexity search and URL fetching.

## Tools (16)

shell, write_file, read_file, edit_file, list_directory, glob, grep, web_search, web_fetch, screenshot, gui_click, gui_type, gui_key, gui_scroll, sub_agent, think, done

## Key Design Decisions

- **Dual model**: Opus plans, Sonnet executes. `think(request_replan: true)` triggers Opus re-plan.
- **Multi-tool turns**: All tool_use blocks in a response are executed, not just the first.
- **Context compaction**: Old messages are summarized into a structured recap at 40 messages instead of being dropped.
- **State persistence**: Saved every 10 steps and on max_steps. Resume with `Penbot.resume(id)`.
- **Sub-agents**: Isolated context, 50-step cap, depth capped at 3.
- **Container**: Agent runs as root. Xvfb on :99 for GUI. Volume `penbot-data` for persistence.

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
- Container image: `penbot-vm:latest`
- Container name: `penbot-vm`
- Logs: `logs/penbot.log`
- Screenshots: `screenshots/`
- Run state: `runs/<id>/state.json`
