---
description: Run the Golem test suite and triage any failures
---

Run the default test suite with `mix test` (this excludes `:e2e` tagged tests, which hit the real Claude API and cost money).

If the user passes a path or filter as `$ARGUMENTS`, run `mix test $ARGUMENTS` instead.

If any tests fail:
1. Read each failing test and the code it covers.
2. Fix the underlying issue — do not weaken assertions or add try/rescue blocks to make tests pass.
3. Re-run only the failing files until green, then run `mix test` once more to confirm nothing else regressed.

Do not run `mix test.e2e` or `mix test --include e2e` unless the user explicitly asks — those tests cost real API tokens.
