# Golem

Autonomous agent that takes a goal, plans with Claude Opus, and executes with Claude Sonnet inside a sandboxed podman container.

```
Goal --> Opus (plan) --> Sonnet (execute in loop) --> Done
                            |
                       podman container (shell, files, GUI)
```

## Requirements

- Podman (or Docker)
- Erlang/OTP 27+ — to run the `golem` binary
- Elixir 1.19+ — only needed to build from source
- `bat` (optional, for syntax-highlighted diffs): `brew install bat`

## Setup

```bash
# 1. Build the binary (one time; needs Elixir + this repo)
mix deps.get
mix escript.build

# 2. Put the binary on your PATH. Pick whichever your shell already
#    has — `echo $PATH` to check. Common picks:
mv golem /usr/local/bin/        # always on PATH, may need sudo
# or:
mv golem ~/bin/                  # add `export PATH="$HOME/bin:$PATH"` to your shell rc if it's not already there

# 3. Configure project + workspace. Either a project-local
#    `./.golem/config.yaml` (preferred when iterating in a clone) or
#    `~/.golem/config.yaml` (preferred for the binary, since you can
#    `golem run` from anywhere).
mkdir -p ~/.golem && cp .golem/config.example.yaml ~/.golem/config.yaml
$EDITOR ~/.golem/config.yaml

# 4. Export secrets in your shell rc (~/.zshrc, ~/.bashrc) — the
#    binary reads them from the environment, never from a file.
export ANTHROPIC_API_KEY=sk-ant-...
export JIRA_EMAIL=you@company.com
export JIRA_API_TOKEN=...
export BITBUCKET_API_TOKEN=...

# 5. Verify
golem doctor
```

That's it. The container and image are provisioned automatically on the first `golem run` — no manual `podman build` step. The Dockerfile + entrypoint are embedded in the binary, so the image build works wherever `golem` runs from.

The config-file lookup checks `./.golem/config.yaml` first, then `~/.golem/config.yaml`. Drop your config in whichever fits your workflow.

### Onboarding checklist

To get a coworker from zero to `golem run --jira SA-1111`:

- [ ] `podman` (or `docker`) installed and runnable
- [ ] `erl` on their PATH (Erlang/OTP 27+)
- [ ] The `golem` binary on PATH (built once via `mix escript.build`, then shared)
- [ ] `ANTHROPIC_API_KEY` exported in their shell
- [ ] `JIRA_EMAIL` + `JIRA_API_TOKEN` exported (Atlassian API token, scopes: `read:jira-work`, `write:jira-work`)
- [ ] `BITBUCKET_API_TOKEN` exported (Bitbucket app password, scopes: Repositories Read+Write, Pull requests Write)
- [ ] An SSH key in `ssh/id_ed25519` (next to their `config.yaml`) with the public key registered on Bitbucket — see *Git access* below
- [ ] A filled-in `.golem/config.yaml` — at minimum `bitbucket.workspace`, `jira.base_url`, and the `projects:` list pointing at the repos they want the agent to work on
- [ ] `golem doctor` returns all green

Then `golem run --jira SA-1111` works end-to-end on the first invocation. The first run is slow because the container image builds once.

### Developing on golem itself

If you're hacking on golem (not just using it), clone the repo and use `mix` directly. In that mode, `.env` is auto-loaded by `dotenv` (a dev/test-only dependency that's not bundled into the production binary), so you can keep secrets in a file rather than your shell rc:

```bash
git clone <this repo>
cd penbot
mix deps.get
cp .env.example .env && $EDITOR .env
cp .golem/config.example.yaml .golem/config.yaml
mix golem.doctor
```

Every `golem <cmd>` is also exposed as `mix golem.<cmd>` (same implementation, thin shim) — use whichever you prefer. The binary is the right answer for everyday use; mix tasks are convenient when iterating on golem itself.

### Environment variables (`.env`)

| Variable | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | Yes | Claude API key |
| `OPENROUTER_API_KEY` | If any `models.*.provider: openrouter` | OpenRouter API key — required when routing a role through OpenRouter (Qwen / Kimi / DeepSeek / etc). Get one at <https://openrouter.ai/keys>. |
| `PERPLEXITY_API_KEY` | For web_search | Perplexity API key |
| `JIRA_EMAIL` | For `--jira` | Atlassian account email |
| `JIRA_API_TOKEN` | For `--jira` | Atlassian API token |
| `BITBUCKET_API_TOKEN` | For `--jira` (push/PR) | Bitbucket app password |
| `GIT_USER` | No | Git commit author name (forwarded into container) |
| `GIT_EMAIL` | No | Git commit author email (forwarded into container) |

All `GOLEM_*` env vars (listed in the table below) override settings from `.golem/config.yaml`.

### Configuration — one file, everything

Everything non-secret lives in **`.golem/config.yaml`**. There's no separate `projects.yml` / `jira.yml` / `mcp.yml` — they were consolidated. See `.golem/config.example.yaml` for a fully-annotated template.

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
2. `.golem/config.yaml` — your config
3. Built-in default in `lib/golem/application.ex`

Run `golem config` to see the resolved scalar values + where each came from. Run `golem doctor` for a full health check (YAML parse, mount paths exist, container reachable, tokens set, MCP servers responsive, etc.).

#### `models` / `limits` / `container.*` scalars

| YAML key | Env var | Default | Description |
|---|---|---|---|
| `models.planner.model` | `GOLEM_PLANNER_MODEL` | `claude-opus-4-7` | Model used to plan and revise. Each role under `models:` is a map of `provider` + `model`. |
| `models.planner.provider` | `GOLEM_PLANNER_PROVIDER` | `anthropic` | Provider for the planner role. One of `anthropic`, `openrouter`. |
| `models.executor.model` | `GOLEM_EXECUTOR_MODEL` | `claude-sonnet-4-6` | Model used to execute steps. Default is Sonnet — ~5× cheaper and faster than Opus, reliable on repetitive read/edit/test loops. Switch to `claude-opus-4-7` if you see quality regressions. |
| `models.executor.provider` | `GOLEM_EXECUTOR_PROVIDER` | `anthropic` | Provider for the executor role. |
| `models.compaction` | `GOLEM_COMPACTION_MODEL` | (uses executor) | Model used to summarize context during compaction |
| `providers.anthropic.api_key_env` | — | `ANTHROPIC_API_KEY` | Env var to read the Anthropic key from |
| `providers.openrouter.api_key_env` | — | `OPENROUTER_API_KEY` | Env var to read the OpenRouter key from |
| `providers.openrouter.base_url` | — | `https://openrouter.ai/api/v1` | Override for self-hosted OpenRouter gateways |
| `limits.max_steps` | `GOLEM_MAX_STEPS` | `200` | Hard step ceiling for a run |
| `limits.max_cost` | `GOLEM_MAX_COST` | `10.0` | Cost ceiling in USD |
| `limits.thinking_budget` | `GOLEM_THINKING_BUDGET` | unset | Extended thinking budget. **Caveat**: enabling this on Opus 4.7 disables prompt caching — each call creates a fresh cache entry. Leave unset unless reasoning quality matters more than the ~90% input-token discount. |
| `limits.command_timeout` | `GOLEM_COMMAND_TIMEOUT` | `900000` | Shell command timeout (ms) |
| `limits.stall_timeout` | `GOLEM_STALL_TIMEOUT` | `120000` | Stall detection timeout (ms, no output) |
| `limits.planner_max_tokens` | `GOLEM_PLANNER_MAX_TOKENS` | `16000` | Max tokens per planner response |
| `limits.planner_max_steps` | `GOLEM_PLANNER_MAX_STEPS` | `75` | Step cap for the planner phase |
| `limits.executor_max_tokens` | `GOLEM_EXECUTOR_MAX_TOKENS` | `16000` | Max tokens per executor response |
| `limits.context_window` | `GOLEM_CONTEXT_WINDOW` | `200000` | Total prompt budget per model call. Raising above 200K auto-enables Anthropic's 1M-context beta (`anthropic-beta: context-1m-2025-08-07`); tokens past 200K bill at 2× input. Compaction triggers at `context_window − 15000`. |
| `jira.comment_on_ticket` | `GOLEM_JIRA_COMMENT_ON_TICKET` | `true` | Post status comments on the Jira ticket (evaluation, success, failure, paused, error). Set to `false` to keep the ticket activity stream clean while still pushing PRs. |
| `container.name` | `GOLEM_CONTAINER` | `golem-vm` | Podman/docker container name |
| `container.image` | `GOLEM_CONTAINER_IMAGE` | `localhost/golem-vm:latest` | Image used to create the container |
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

Check connectivity: `golem mcp` or `golem doctor`.

### Health check

```bash
golem doctor
```

Validates the full setup in one command — YAML parses, mounts resolve, container is reachable, env vars set, MCP servers responsive, Jira/Bitbucket creds present. Exits non-zero on any failure (CI-friendly).

### Git access (optional)

To let the bot push/pull from GitHub or Bitbucket, generate a dedicated SSH key:

```bash
mkdir -p ssh
ssh-keygen -t ed25519 -f ssh/id_ed25519 -N "" -C "golem-bot"
```

Add the public key (`ssh/id_ed25519.pub`) to your GitHub/Bitbucket account. The `ssh/` directory is gitignored — keys stay local. The default `container.mounts` block in `config.example.yaml` already mounts `ssh/` read-only into `/home/agent/.ssh`, so no container rebuild needed — just recreate:

```bash
podman rm -f golem-vm   # next `golem run` will recreate with the new mount
```

## Usage

### Run a scenario

```bash
golem run --scenario smoke_maze
```

### Run with a custom goal

```bash
golem run "Build a REST API in Python"
```

### Run a Jira ticket

```bash
golem run --jira SA-1111

# Add an --nudge to steer interpretation when the ticket offers
# multiple approaches or is ambiguous. The note is injected near the
# top of the goal and is also visible to the pre-flight evaluator.
golem run --jira SA-1111 --nudge "go with approach 2 from the description"
```

Other `--jira` flags: `--force` (skip evaluation), `--budget <n>` (raise the cost ceiling), `--max-steps <n>`, `--visual` (require browser verification), `--model <id>`.

### Resume a paused run

```bash
golem resume --list
golem resume <run_id>
```

### Iterate on a PR (apply reviewer feedback)

After Golem has opened a PR and a human reviewer leaves feedback, drive
another pass with `golem iterate`. The agent fetches unresolved
comments **and** unresolved Bitbucket PR tasks, checks out the PR's
existing branch as a worktree, addresses the feedback, pushes back to
the same branch, and replies on each affected thread with the head
commit SHA. Tasks are framed as binding action items; comments are
weighted by type (suggestion / question / nit).

```bash
# By Jira ticket key — the most common case. Resolves to whichever
# open PR has a `golem/<KEY>-…` source branch.
golem iterate SA-2100

# By workspace/repo/PR id, when you only have the URL handy.
golem iterate hrdl/api/3480
golem iterate https://bitbucket.org/hrdl/api/pull-requests/3480

# Bare invocation lists open bot PRs with unresolved-item counts
# (comments + tasks) — informative, not active. Use it when you don't
# remember which ticket key you want.
golem iterate

# Cost ceiling and step ceiling work the same way as `golem run`.
golem iterate SA-2100 --budget 20
```

Threads and tasks are NOT auto-resolved — that authority stays with
the human reviewer. Bot replies only post `Addressed in <sha>` with a
one-line summary, deduped per parent thread when a comment and a task
share one.

The command is named `iterate` because "iterate on a PR" matches how
engineers describe addressing review feedback. The name `review` is
reserved for a future feature where Golem itself reviews a PR (posts
comments, points out bugs).

### Export files from container

```bash
golem export /home/agent/project ./output/project
```

## Scenarios

Test scenarios live in `scenarios/`. Run with `--scenario <name>`:

| Scenario | Difficulty | Steps | Description |
|---|---|---|---|
| `smoke_maze` | Easy | 3-5 | Basic Python smoke test |
| `cli_sitemap` | Medium | 30-40 | CLI tool build |
| `rest_api_bookmarks` | Medium | 20-40 | Flask REST API |
| `gui_snake` | Medium | 20-30 | GUI rendering test |

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
- **Context compaction**: Full LLM-powered summary triggered only when estimated tokens get within 15K of the configured `limits.context_window`. Old tool_results are kept verbatim — clearing them caused re-read loops.
- **Read-only parallelism**: Concurrent-safe tools (grep, glob, read_file) run in parallel; mutating tools run serially.
- **Fuzzy edit matching**: Whitespace-normalized fallback when exact `old_string` match fails.
- **Sub-agents**: Isolated context, 50-step cap, depth capped at 3.
