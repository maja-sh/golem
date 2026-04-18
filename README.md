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
# 1. Install dependencies
mix deps.get

# 2. Copy the config template and fill in your values
cp .golem/config.example.yml .golem/config.yml

# 3. Fill in .env (ANTHROPIC_API_KEY minimum)
cp .env.example .env

# 4. Verify everything is wired up correctly
mix golem.doctor
```

That's it. The container and image are provisioned automatically on the first `mix golem.run` — no manual `podman build` or `./start.sh` step.

### Environment variables (`.env`)

| Variable | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | Yes | Claude API key |
| `PERPLEXITY_API_KEY` | For web_search | Perplexity API key |
| `DISCORD_TOKEN` | For daemon/`ask_user` | Discord bot token |
| `DISCORD_CHANNEL_ID` | For daemon/`ask_user` | Discord channel ID |
| `JIRA_EMAIL` | For `--jira` | Atlassian account email |
| `JIRA_API_TOKEN` | For `--jira` | Atlassian API token |
| `BITBUCKET_API_TOKEN` | For `--jira` (push/PR) | Bitbucket app password |
| `GIT_USER` | No | Git commit author name (forwarded into container) |
| `GIT_EMAIL` | No | Git commit author email (forwarded into container) |

All `GOLEM_*` env vars (listed in the table below) override settings from `.golem/config.yml`.

### Configuration — one file, everything

Everything non-secret lives in **`.golem/config.yml`**. There's no separate `projects.yml` / `jira.yml` / `mcp.yml` — they were consolidated. See `.golem/config.example.yml` for a fully-annotated template.

Top-level keys:

```yaml
models:      # which Claude models to use
limits:      # step caps, cost ceilings, timeouts
container:   # container name, image, user, mounts, env
projects:    # repos the agent works on and how to set them up
bitbucket:   # workspace slug
default_branch: main
jira:        # base_url + transition name
mcp:         # external tool servers
```

**Precedence** (highest first):

1. `GOLEM_*` environment variable — per-shell override for CI/ops
2. `.golem/config.yml` — your config
3. Built-in default in `lib/golem/application.ex`

Run `mix golem.config` to see the resolved scalar values + where each came from. Run `mix golem.doctor` for a full health check (YAML parse, mount paths exist, container reachable, tokens set, MCP servers responsive, etc.).

#### `models` / `limits` / `container.*` scalars

| YAML key | Env var | Default | Description |
|---|---|---|---|
| `models.planner` | `GOLEM_PLANNER_MODEL` | `claude-opus-4-7` | Model used to plan and revise |
| `models.executor` | `GOLEM_EXECUTOR_MODEL` | `claude-sonnet-4-6` | Model used to execute steps. Default is Sonnet — ~5× cheaper and faster than Opus, reliable on repetitive read/edit/test loops. Switch to `claude-opus-4-7` if you see quality regressions. |
| `models.compaction` | `GOLEM_COMPACTION_MODEL` | (uses executor) | Model used to summarize context during compaction |
| `limits.max_steps` | `GOLEM_MAX_STEPS` | `200` | Hard step ceiling for a run |
| `limits.max_cost` | `GOLEM_MAX_COST` | `10.0` | Cost ceiling in USD |
| `limits.thinking_budget` | `GOLEM_THINKING_BUDGET` | unset | Extended thinking budget. **Caveat**: enabling this on Opus 4.7 disables prompt caching — each call creates a fresh cache entry. Leave unset unless reasoning quality matters more than the ~90% input-token discount. |
| `limits.command_timeout` | `GOLEM_COMMAND_TIMEOUT` | `900000` | Shell command timeout (ms) |
| `limits.stall_timeout` | `GOLEM_STALL_TIMEOUT` | `120000` | Stall detection timeout (ms, no output) |
| `limits.planner_max_tokens` | `GOLEM_PLANNER_MAX_TOKENS` | `16000` | Max tokens per planner response |
| `limits.planner_max_steps` | `GOLEM_PLANNER_MAX_STEPS` | `75` | Step cap for the planner phase |
| `limits.executor_max_tokens` | `GOLEM_EXECUTOR_MAX_TOKENS` | `16000` | Max tokens per executor response |
| `container.name` | `GOLEM_CONTAINER` | `golem-vm` | Podman/docker container name |
| `container.image` | `GOLEM_CONTAINER_IMAGE` | `golem-vm:latest` | Image used to create the container |
| `container.user` | `GOLEM_CONTAINER_USER` | `agent` | Default setup-step user |

#### `container.mounts` — host → container volume mounts

Applied when Golem creates the container. Each entry:

```yaml
container:
  mounts:
    - src: ssh                                          # host path (relative to repo root, or absolute)
      dest: /home/agent/.ssh                            # absolute container path
      readonly: true                                    # default false
      required: false                                   # missing src silently skipped unless true
    - src: .golem/gcloud-sa.json
      dest: /home/agent/.config/gcloud/application_default_credentials.json
      readonly: true
```

Missing `src` paths are silently skipped unless `required: true`.

#### `container.env` — environment variables inside the container

Two forms supported:

```yaml
container:
  env:
    # 1. Bare string — pass through from host env if set + non-empty
    - GIT_USER
    - GIT_EMAIL

    # 2. Map — static value, optionally gated on a host file existing
    - name: GOOGLE_APPLICATION_CREDENTIALS
      value: /home/agent/.config/gcloud/application_default_credentials.json
      when_file: .golem/gcloud-sa.json
```

#### `projects` — repos the agent works on

```yaml
bitbucket:
  workspace: your-workspace

default_branch: main

projects:
  - repo: your-workspace/api
    path: /home/agent/api
    description: "One-paragraph project summary — injected into the planner prompt."
    branch_from: main                     # optional, overrides default_branch
    cache: [vendor, node_modules]         # dirs copied from main clone to worktree before setup
    instructions: |                       # optional — golem-only rules (verification, etc.)
      This project has no test suite. Verify with `npm run build`.
    setup:
      - label: "composer install"
        run: "composer install --no-interaction"
        user: agent                       # omit to run as root (default)
```

| Field | Required | Description |
|---|---|---|
| `repo` | yes | `<workspace>/<slug>` path |
| `path` | yes | Absolute path inside the container where the repo is cloned |
| `description` | no | Human summary, included in planner prompts |
| `branch_from` | no | Base branch (overrides `default_branch`) |
| `cache` | no | List of dirs to copy from the main clone to each task's worktree (speeds up installs) |
| `instructions` | no | Golem-specific rules injected into the agent prompt |
| `setup` | no | Steps run after cloning. Each has `label`, `run`, optional `user`. |

#### `jira` — Jira integration

```yaml
jira:
  base_url: https://yoursite.atlassian.net
  done_transition: "Pull Request / Deployable"   # status to transition to on success (default: "Done")
```

#### `mcp` — external tool servers

Two transports: stdio (spawn a subprocess) and HTTP.

```yaml
mcp:
  servers:
    # stdio
    - name: elastic
      command: npx
      args: ["-y", "@elastic/mcp-server-elasticsearch"]
      env:
        ELASTICSEARCH_URL: "${ES_URL}"        # ${VAR} expands from host env
        ELASTICSEARCH_API_KEY: "${ES_KEY}"

    # http
    - name: remote-tools
      url: "http://localhost:3000/mcp"
      headers:
        Authorization: "Bearer ${MY_TOKEN}"
```

Check connectivity: `mix golem.mcp` or `mix golem.doctor`.

### Health check

```bash
mix golem.doctor
```

Validates the full setup in one command — YAML parses, mounts resolve, container is reachable, env vars set, MCP servers responsive, Jira/Bitbucket creds present. Exits non-zero on any failure (CI-friendly).

### Git access (optional)

To let the bot push/pull from GitHub or Bitbucket, generate a dedicated SSH key:

```bash
mkdir -p ssh
ssh-keygen -t ed25519 -f ssh/id_ed25519 -N "" -C "golem-bot"
```

Add the public key (`ssh/id_ed25519.pub`) to your GitHub/Bitbucket account. The `ssh/` directory is gitignored — keys stay local. The default `container.mounts` block in `config.example.yml` already mounts `ssh/` read-only into `/home/agent/.ssh`, so no container rebuild needed — just recreate:

```bash
podman rm -f golem-vm   # next mix golem.run will recreate with the new mount
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

## Per-run event log

Each run writes a structured event log to `runs/<id>/events.jsonl` — one JSON object per line, covering every tool call, API call, sub-agent, compaction, and warning. Use it for post-mortems, replay, or as the basis for a dashboard.

```bash
# Everything that happened
jq . runs/<id>/events.jsonl | less

# Cost per step
jq 'select(.type == "api_call") | [.step, .payload.input_tokens, .payload.cache_read]' runs/<id>/events.jsonl

# All shell commands that failed
jq 'select(.type == "tool_result" and .payload.error == true and .payload.name == "shell") | .payload.preview' runs/<id>/events.jsonl
```

The prose log at `logs/golem.log` is intentionally minimal — only warnings and errors. For per-step detail, read the events file.

## Tests

```bash
mix test                 # default suite — excludes :e2e tags
mix test.e2e             # only end-to-end tests (hit the real Claude API)
mix test --include e2e   # default + e2e
```

Unit tests cover pure logic (`Golem.Runner.Compaction`, `Golem.Runner.Triggers`, `Golem.Runner.Reminder`, cache breakpoints, prompt structure, config loader, TUI helpers). End-to-end tests in `test/e2e/` hit the real Anthropic API, cost money, and are excluded from the default run.

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
