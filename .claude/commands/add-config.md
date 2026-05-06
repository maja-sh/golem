---
description: Add a new config setting with all required documentation updates
---

Add a new config setting to Golem. The setting to add: `$ARGUMENTS`

If `$ARGUMENTS` is empty or vague, ask the user for: yaml path (e.g. `models.planner`), env var name (e.g. `GOLEM_PLANNER_MODEL`), type (string/integer/boolean/list), default value, and a one-line description.

Then make all of these edits in a single pass — the project requires every config setting to be wired in **all** of these places:

1. **`lib/golem/config.ex`** — append a row to `@settings` with the yaml path, env var, and type.
2. **`lib/golem/application.ex`** — add the hard-coded default in `ensure_defaults/0`.
3. **`.golem/config.example.yml`** — add the key with a comment showing the default.
4. **`AGENTS.md`** — document the key under the relevant config section. (Note: `CLAUDE.md` and `GEMINI.md` are symlinks to `AGENTS.md` — only edit `AGENTS.md`.)
5. **`README.md`** — add a row/line in the human-readable config reference.
6. **`docs/config.md`** — add the full schema entry (this is the source of truth for detailed docs).

After editing, run `mix golem.config` to confirm the new key resolves correctly, and `mix compile --warnings-as-errors` to confirm no compile warnings.
