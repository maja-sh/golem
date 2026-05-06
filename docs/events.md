# Per-run event log

Every non-trivial thing that happens during a run is appended as a JSON line to `runs/<run_id>/events.jsonl`. The emitter lives in `lib/golem/events.ex` and is called from `runner.ex` + `tool_handler.ex`. The file is the canonical record for post-mortem analysis and replay.

## Event shape

```json
{"ts":"2026-04-17T15:30:12.345Z","type":"tool_call","step":12,"depth":0,"payload":{"name":"shell","input":{"command":"..."},"tool_use_id":"..."}}
```

`step` and `depth` are hoisted to top-level when the caller provides them, so `jq '.[] | select(.step > 50)'` works without digging into `.payload`.

## Event types

| Type | Emitted from | Notes |
|---|---|---|
| `run_start` / `run_end` / `run_paused` / `run_resumed` / `run_error` | runner `run/2`, `resume/2` | Lifecycle markers |
| `step` | runner `do_loop/1` | One per main-loop iteration |
| `api_call` | runner after `Golem.Claude.call` | Model, elapsed ms, token usage, cache counts |
| `agent_text` | runner, when the model produces prose | |
| `tool_call` / `tool_result` | runner `execute_single_tool/4` + concurrent batch | Every invocation, including retries |
| `thought` | `Golem.ToolHandler.execute/2` for `think` | `request_replan` flag included |
| `sub_agent_start` / `sub_agent_end` / `sub_agent_skipped` | runner `run_sub_agent/4`, tool_handler dedup | |
| `plan_created` | runner after `create_plan/2` | Plan text + phase/step counts |
| `replan_start` / `replan_done` | runner `handle_replan/5` | |
| `compaction` | runner `snip_messages/1` + `do_trim_messages/1` | Reports type: `snip` or `full` |
| `stuck` / `think_loop` / `drift` / `drift_check` / `staleness_nudge` / `file_size_warning` | runner warning injectors | |
| `verify_start` / `verify_done` | runner `maybe_verify/2` | Adversarial verifier gate |
| `no_tool_response` | runner | Agent returned text with no tool call |
| `agents_md_discovered` | runner planner | |

Prose logging in `logs/golem.log` is intentionally sparse — only `Logger.warning` / `Logger.error` fire there. For anything per-step, read the events file.

## Reading back

```bash
jq . runs/<id>/events.jsonl | less
jq 'select(.type == "tool_call") | .payload.name' runs/<id>/events.jsonl | sort | uniq -c
jq 'select(.type == "api_call") | [.step, .payload.elapsed_ms, .payload.input_tokens]' runs/<id>/events.jsonl
```

Or from Elixir: `Golem.Events.read(run_id)` returns a list of decoded maps.
