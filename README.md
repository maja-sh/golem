# Golem

Autonomous agent that takes a goal, plans with Claude Opus, and executes with Claude Sonnet inside a sandboxed podman container.

```
Goal --> Opus (plan) --> Sonnet (execute in loop) --> Done
                            |
                       podman container (shell, files, GUI)
```

## Requirements

- Elixir 1.19+ / OTP 27+
- Podman (or Docker)
- `bat` (optional, for syntax-highlighted diffs): `brew install bat`

## Setup

```bash
# Install dependencies
mix deps.get

# Build the container image
podman build -t golem-vm:latest -f containers/Dockerfile containers/

# Start the container
./containers/start.sh

# Configure environment
cp .env.example .env
# Edit .env with your API keys
```

### Environment variables

Set in `.env`:

| Variable | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | Yes | Claude API key |
| `PERPLEXITY_API_KEY` | For web_search | Perplexity API key |
| `DISCORD_TOKEN` | For daemon mode | Discord bot token |
| `DISCORD_CHANNEL_ID` | For daemon mode | Discord channel ID |
| `GIT_USER` | No | Git commit author name |
| `GIT_EMAIL` | No | Git commit author email |

### Git access (optional)

To let the bot push/pull from GitHub or Bitbucket, generate a dedicated SSH key:

```bash
mkdir -p ssh
ssh-keygen -t ed25519 -f ssh/id_ed25519 -N "" -C "golem-bot"
```

Add the public key (`ssh/id_ed25519.pub`) to your GitHub/Bitbucket account as an SSH key. The `ssh/` directory is gitignored -- keys stay local.

Recreate the container after setup:

```bash
podman rm -f golem-vm && ./containers/start.sh
```

## Usage

### Run a scenario

```bash
mix golem.run --scenario smoke_maze
```

### Run with a custom goal

```bash
mix golem.run "Build a REST API in Python"
```

### Resume a paused run

```bash
mix golem.resume --list
mix golem.resume <run_id>
```

### Export files from container

```bash
mix golem.export /home/agent/project ./output/project
```

### Daemon mode (Discord-controlled)

```bash
mix golem.daemon
```

Discord commands: `run <scenario>`, `run "custom goal"`, `fix <project>: <description>`, `resume`, `status`, `stop`, `runs`

## Scenarios

Test scenarios live in `scenarios/`. Run with `--scenario <name>`:

| Scenario | Difficulty | Steps | Description |
|---|---|---|---|
| `smoke_maze` | Easy | 3-5 | Basic Python smoke test |
| `cli_sitemap` | Medium | 30-40 | CLI tool build |
| `rest_api_bookmarks` | Medium | 20-40 | Flask REST API |
| `gui_snake` | Medium | 20-30 | GUI rendering test |
| `money_maker` | Hard | 150-300 | Research + plan + build cycle |
| `chainpost_backend` | Hard | 200-400 | Rust blockchain microblogging |
| `chainpost_frontend` | Hard | 150-300 | Tauri + React desktop client |

## Architecture

- **Runner** (`lib/golem/runner.ex`) -- Main loop: plan, execute, re-plan, compact, persist.
- **Claude** (`lib/golem/claude.ex`) -- API client with prompt caching and exponential backoff.
- **Sandbox** (`lib/golem/sandbox.ex`) -- GenServer wrapping `podman exec` with sentinel-based output parsing.
- **Verify** (`lib/golem/verify.ex`) -- Programmatic + sub-agent verification gate before accepting `done`.
- **Tools** (`lib/golem/tools.ex`) -- Tool definitions. 18 tools including shell, file ops, web, GUI, sub-agents.
- **ToolHandler** (`lib/golem/tool_handler.ex`) -- Tool dispatch with fuzzy edit matching and file caching.
- **Prompt** (`lib/golem/prompt.ex`) -- System prompts with static/dynamic cache split.
- **State** (`lib/golem/state.ex`) -- Save/load run state for resume.

### Key design decisions

- **Dual model**: Opus plans, Sonnet executes. `think(request_replan: true)` triggers re-planning.
- **Verification gate**: When the agent calls `done`, the runner runs compile+test and spawns an adversarial verification sub-agent before accepting.
- **Prompt cache split**: Static instructions are cached across turns; dynamic content (errors, AGENTS.md) doesn't break the cache.
- **Microcompaction**: Old tool results are cleared every turn; full LLM-powered compaction at 40 messages.
- **Read-only parallelism**: Concurrent-safe tools (grep, glob, read_file) run in parallel; mutating tools run serially.
- **Fuzzy edit matching**: Whitespace-normalized fallback when exact `old_string` match fails.
- **Sub-agents**: Isolated context, 50-step cap, depth capped at 3.
