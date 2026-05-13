# Configuration Reference

User-facing config lives in `.golem/config.yaml` (see `.golem/config.example.yaml` for the template). `Golem.Config.load/0` runs at application boot and merges three layers in precedence order: `GOLEM_*` env vars → `.golem/config.yaml` → built-in defaults in `Golem.Application.ensure_defaults/0`.

Run `mix golem.config` to print the resolved values and their source.

## Top-level YAML keys

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
  context_window: 200000         # GOLEM_CONTEXT_WINDOW

providers:                       # Per-provider settings (all optional)
  anthropic:
    api_key_env: ANTHROPIC_API_KEY
  openrouter:
    api_key_env: OPENROUTER_API_KEY
    base_url: https://openrouter.ai/api/v1

# Each role is a map of `provider` + `model`.
#
# models:
#   planner:
#     provider: anthropic
#     model: claude-opus-4-7
#   executor:
#     provider: openrouter
#     model: qwen/qwen-2.5-coder-32b-instruct

jira:
  comment_on_ticket: true        # GOLEM_JIRA_COMMENT_ON_TICKET

container:
  name: golem-vm                 # GOLEM_CONTAINER
  user: agent                    # GOLEM_CONTAINER_USER
```

Adding a new setting: append a row to `@settings` in `lib/golem/config.ex` (yaml path + env var + type) and add a hard-coded default in `Golem.Application.ensure_defaults/0`. Document the new key in both `README.md` and `AGENTS.md`.

## Project Config

Project setup lives under the `projects:` block in `.golem/config.yaml`:

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

## MCP Servers

External tool servers are configured under the `mcp:` block in `.golem/config.yaml`:

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
| `JIRA_EMAIL` | for Jira | Atlassian account email | Shared with Bitbucket basic auth |
| `JIRA_API_TOKEN` | for Jira | Atlassian API token | `read:jira-work`, `write:jira-work` (read issues, post comments) |
| `BITBUCKET_API_TOKEN` | for Bitbucket | Bitbucket app password | `Repositories: Read`, `Repositories: Write`, `Pull requests: Write` (clone, push, create PRs) |
| `GIT_USER` | no | Git author name in container | Defaults to "Golem Bot" |
| `GIT_EMAIL` | no | Git author email in container | Defaults to "golem@bot.local" |

## System Dependencies

- `podman` — Container runtime (required)
- `bat` — Syntax highlighting in diffs (optional, falls back to plain text). Install: `brew install bat`
