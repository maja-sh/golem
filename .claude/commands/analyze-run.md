---
description: Analyze a Golem run's event log to diagnose what happened
---

Analyze the event log for a Golem run. Run id or path: `$ARGUMENTS`

If `$ARGUMENTS` is empty, list the most recent runs with `ls -lt runs/ | head -20` and ask the user which one.

Steps:
1. Read `runs/<run_id>/events.jsonl` — this is the canonical record (one JSON event per line, emitted by `lib/golem/events.ex`).
2. Read `runs/<run_id>/state.json` for the final state if present.
3. Use `jq` to summarize: count events by type, show the tool-call sequence, surface any errors or replan triggers, and identify where the run terminated.
4. If the run failed or got stuck, identify the likely cause from the event sequence — don't speculate beyond what the events show.

Report findings as: total steps, tools used (with counts), key decision points (think calls, replans), and the failure mode if any. Keep prose short; the user can read the events themselves.

Do not modify any files in `runs/` — those are immutable post-run records.
