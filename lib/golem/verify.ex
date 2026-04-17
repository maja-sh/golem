defmodule Golem.Verify do
  @moduledoc """
  Verification gate for the `done` tool.

  When the agent calls `done(success=true)`, the Runner invokes this module
  to check the work before accepting it:

  1. **Programmatic checks** — detect the project type, run compile + test.
     Fast, deterministic, catches the obvious failures.
  2. **Verification sub-agent** — fresh context, focused on unused code,
     warnings, dead imports, TODO placeholders. Catches what the fatigued
     main agent missed after 1000+ steps.
  """

  require Logger

  @doc """
  Spawn a fresh sub-agent to do a thorough quality review.

  The sub-agent has zero prior context — no fatigue, no assumptions.
  It only reports issues; it does NOT fix them (the main agent will).

  Returns `:ok` or `{:error, issues_text}`.
  """
  def run_agent(goal_context) do
    goal = """
    You are an adversarial verification agent. Your job is to FIND PROBLEMS in the code that was just written. Do NOT fix anything — report only.

    You have a tight step budget (≈10 steps). Be focused. Verify the intended change — not every diff line.

    ## Context

    The agent was working on this goal:
    #{String.slice(goal_context, 0, 500)}

    ## Required checks

    1. **Look at the diff** — run `git diff HEAD~1 HEAD --stat` to see the scope. If you see a huge number of locale/JSON files touched for a single-key change, that's an auto-translator hook, NOT the agent's work. Verify the INTENDED change (what the task asked for), not every file the translator touched.
    2. **Unused code scan** — `grep -n` in the intentionally-modified files for unused imports, dead functions, TODO/FIXME/HACK placeholders, and commented-out code.
    3. **Scope-appropriate correctness check** — ONE command, the lightest one that actually exercises the change:
       - JSON/YAML/Markdown/locale → `jq empty` on the relevant file, one check.
       - Tests changed → run just those tests.
       - Frontend source → `tsc --noEmit` (or a single `eslint` on the modified files).
       - Backend source → compile/typecheck + focused tests for the affected module.

    Do NOT iterate across every locale or every file — one representative check per category is enough within your step budget. Do NOT run full `npm run build` / `vite build` / `webpack` — they are slow and memory-hungry. Use typecheck/lint instead.

    ## Infra failures are NOT code failures

    If any check is killed (exit 137/143), OOMs, or stalls under memory pressure, that is an infrastructure problem, not a defect in the code. Report it as `Result: INFRA_ERROR` and move on — do NOT mark the overall verdict as failed on this basis alone. Try a lighter equivalent (`tsc --noEmit` instead of full build, `jq empty` instead of running the app). The goal is to catch real bugs, not to fight the container's memory ceiling.

    ## Evidence rules

    Every check MUST include actual command output. Format:
    ```
    ### Check: [what you verified]
    Command: [exact command]
    Output: [actual output — copy-paste, not paraphrased]
    Result: PASS or FAIL
    ```

    CRITICAL: Reading code is NOT verification. "Looks correct" does NOT count. RUN the commands.
    The implementer is an LLM that may have hallucinated — do not trust "tests already pass", verify independently.

    ## Verdict

    If you find ANY issues with the code that was written (not pre-existing issues), call `done(success=false)` with a numbered list.
    If ALL checks genuinely pass with evidence, call `done(success=true)`.

    Do NOT fix anything. Do NOT modify any files. Report only.
    """

    case Golem.Runner.run_sub_agent(
           goal,
           "Adversarial verification. Be thorough, be strict, trust nothing. Report only, do not fix.",
           0,
           nil,
           display_name: "Verification",
           # Cap verifier steps tight — its job is a focused correctness
           # review, not open-ended exploration. A 50-step verifier on
           # Opus 4.7 ran $7+ chasing translator-induced diff churn.
           max_steps: 10
         ) do
      {:ok, %{success: true}} -> :ok
      {:ok, %{success: false, summary: summary}} -> {:error, summary}
      {:error, :max_steps_reached} -> {:error, "Verification agent hit step limit (likely many issues)"}
      {:error, reason} -> {:error, "Verification agent crashed: #{inspect(reason)}"}
    end
  end

end
