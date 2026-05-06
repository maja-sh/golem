---
description: Add a new tool that the agent can call
---

Add a new tool to Golem's tool set. Tool to add: `$ARGUMENTS`

If `$ARGUMENTS` is empty, ask the user for: tool name, what it does, input schema, and whether it should be available to sub-agents (and at what depth).

Wire the new tool through all four layers:

1. **`lib/golem/tools.ex`** — add the tool definition (name, description, input_schema). Confirm whether `for_depth/1` should include it; sub-agents are capped at depth 3.
2. **`lib/golem/tool_handler.ex`** — add the dispatch clause that calls the implementation.
3. **Implementation module** — either extend an existing module (e.g. `Golem.Sandbox`, `Golem.Web`, `Golem.Screenshot`) or create a new one under `lib/golem/`. Match the style of the closest existing tool.
4. **Event emission** — if the tool does anything non-trivial, emit an event from `lib/golem/events.ex` so it shows up in `runs/<id>/events.jsonl`.

Then:
- Add a unit test under `test/` (pure, no network or container).
- Update the tool count and list in `AGENTS.md` (currently "Tools (16)").
- Update the same tool list in `README.md`.

Do not add the tool to e2e tests — those hit the real Claude API and cost money.
