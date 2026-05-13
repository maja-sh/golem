# PinnedStatus

A pinned block of status lines at the bottom of the terminal, with the rest of
your output scrolling above it. Redraws are diffed — when only one line in the
block changes, only that line's bytes hit the wire, so unchanged lines never
flicker or leak into scrollback.

## Why

Most TUI status bars work by:

1. Moving the cursor up over the block
2. Clearing from there to the end of the screen (`\e[J`)
3. Reprinting the whole block

Every redraw — including each spinner tick — wipes the entire block before
rewriting it. On many terminals that wipe is visible as a flash, and some
terminal scrollback implementations capture each wiped state as a separate
line of history.

`PinnedStatus` keeps a copy of the last rendered lines. When you call
`set_status/1` with a new list, it walks both lists in parallel and only
emits clear-line + rewrite for lines that actually changed. Unchanged lines
get a single cursor-down byte.

## Quick start

```elixir
{:ok, _} = PinnedStatus.start_link()

PinnedStatus.set_status([
  "[✓] Task 1",
  "[ ] Task 2",
  "⠋ working… 12s"
])

PinnedStatus.println("some scrolling output above the block")

# Only the third line is rewritten:
PinnedStatus.set_status([
  "[✓] Task 1",
  "[ ] Task 2",
  "⠙ working… 13s"
])

PinnedStatus.stop()
```

## Scope

This package handles **rendering only**. It doesn't know about spinners, tool
icons, themes, or anything domain-specific — those belong in the caller.
