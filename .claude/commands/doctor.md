---
description: Run mix golem.doctor and triage any failures
---

Run `mix golem.doctor` to validate config and runtime prerequisites.

If everything passes, report green and stop.

If anything fails, diagnose and fix in this order:

1. **Config issues** — run `mix golem.config` to see the resolved values and which layer they came from (env var, `.golem/config.yml`, or built-in default). Fix in `.golem/config.yml`.
2. **Missing `.env`** — confirm `ANTHROPIC_API_KEY` is set. Don't print the key value.
3. **Podman / container issues** — check that podman is installed, the `golem-vm:latest` image exists, and the `golem-data` volume is present. Don't recreate the container or volume without asking — they may contain in-progress work.
4. **MCP / Bitbucket / Jira credentials** — only relevant if the user uses those features; surface what's missing but don't try to set credentials yourself.

Re-run `mix golem.doctor` after each fix to confirm. Stop and ask the user before any destructive action (deleting the container, wiping the volume, regenerating credentials).
