# Agent-initiated Discord questions

## Problem

For ambiguous tickets ("use same pattern as X", "decide between A or B"), the agent has two bad options today:

1. **Guess** — picks one interpretation, wastes budget fixing it when wrong.
2. **Abort** — marks rejected, leaves the ticket untouched.

The `ask_user` tool already exists but is rarely invoked because:

- It's off by default unless `DISCORD_TOKEN` + `DISCORD_CHANNEL_ID` are set.
- The executor prompt doesn't push the agent toward using it.
- No clear "when should I ask?" signal from the ticket itself.

## Goal

Let the agent reach out to the operator on Discord when a ticket genuinely needs human judgment, get an answer back, continue the run — without interrupting them for low-stakes decisions.

## Design

### 1. Opt-in per-ticket via a Jira label

Add a Jira label (e.g. `ask-human`) that signals "this ticket will probably need clarification mid-run". When the ticket has that label, the agent prompt gets an extra instruction:

> **This ticket is tagged `ask-human`.** If you hit a decision that significantly affects the outcome — choosing between architectural approaches, picking which table to query when multiple fit, interpreting a vague acceptance criterion — call `ask_user` instead of guessing. Pick your question carefully: you'll only get one or two chances before the operator gets annoyed.

Without the label, the agent still *has* `ask_user` but gets the default guidance ("use only for significant decisions").

**Advantage**: the label is visible in Jira, so the operator knows before a run starts whether it's the kind of ticket that might ping them.

### 2. Conversation shape on Discord

Not a full chat thread — just **question → reply**, single round per invocation.

```
Golem (bot):  [SA-1234] Which invoice filter applies here?
              a) customer_id scoping
              b) account-level scoping
              c) a new hybrid approach
              Recommendation: (a) — matches BulkCourseFilter.

              Reply with "a", "b", "c", or free text.

You (reply):  b — for this ticket we need account-level, and
              BulkCourseFilter is the outlier actually.

Golem (bot):  👍 continuing.
```

The run pauses on `ask_user` until a reply arrives (existing behavior — it already pauses). Reply is passed back as the tool_result.

### 3. Timeout and unsupervised mode

- **Default timeout**: 30 min. If the operator doesn't reply, the agent gets `"No response. Use your best judgment and continue."` as the tool_result and proceeds — doesn't block forever.
- **Max questions per run**: 3. Above that, injections into the prompt say "you've burned your question budget; decide yourself." Prevents spam.
- **`--no-ask` flag** on `mix golem.run` to disable the tool entirely for a run even with Discord configured (useful for CI).

### 4. Surface in TUI + events

- TUI: `⏸ Awaiting reply: "Which invoice filter..."` in the status area until answered.
- `events.jsonl`: `{type: "ask_user", payload: {question, answer, elapsed_ms}}` so post-mortems can see which decisions were punted to the operator.

## What's already there vs what's new

**Already works** (`lib/golem/tool_handler.ex` and `lib/golem/discord/`):

- `ask_user` tool is registered when `DISCORD_TOKEN` is set.
- Tool handler posts to Discord and blocks on a reply.

**New**:

- Label detection in `Golem.Jira.Integration.run_ticket`, injecting the "ask-human" nudge into the prompt.
- Timeout on the Discord waiter (currently blocks indefinitely).
- Per-run question budget enforcement.
- `--no-ask` flag.
- TUI status line for "awaiting reply" state.
- `:ask_user` event emission.

## Alternative: conversational chat

A real multi-turn chat loop (agent → operator → agent → operator …) would require:

- Persistent Discord thread per ticket, with multi-turn context.
- A new state machine where the agent pauses after each message waiting for a reply.

That's a much bigger change. Start with the **single-round question** pattern above — it covers 90% of "I'm genuinely unsure" cases and keeps the prompt transactional. If operators end up clarifying multiple times per question, upgrade to chat later.

## Effort estimate

- **Small first milestone** (label + prompt nudge + timeout + `--no-ask`): ~2-3 hours.
- **Full proposal** (label + timeout + budget + TUI + events + flag): ~half a day.

## Open questions

- Label name — `ask-human`, `talk-to-hampus`, something else? Needs to be project-agnostic since the tool might ship to other teams.
- Where to configure the Discord channel per-project vs globally? Currently one channel via `DISCORD_CHANNEL_ID`. Multi-project teams might want per-repo routing.
- Does the question budget reset on `--resume`? Probably not — resume inherits the outer run's budget.
