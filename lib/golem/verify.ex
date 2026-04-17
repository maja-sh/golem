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

    ## Context

    The agent was working on this goal:
    #{String.slice(goal_context, 0, 500)}

    ## Required checks

    1. **Look at the diff first** — run `git diff` (or `git diff HEAD~1`) to see exactly what changed. This determines which checks are relevant. Reading the diff is mandatory; the checks below depend on it.
    2. **Unused code scan** — `grep -n` in the modified files for unused imports, dead functions, TODO/FIXME/HACK placeholders, and commented-out code. Always do this.
    3. **Scope-appropriate correctness check** — pick the lightest check that actually exercises the change:
       - Only JSON/YAML/Markdown/locale files → syntax check (`jq empty file.json`, `yamllint`, `node -e "JSON.parse(...)"`). Do NOT run a full frontend build.
       - Only tests changed → run just those tests (e.g. `pytest path/to/test.py`, `vitest run path/to/test.spec.ts`).
       - Frontend source changed → run the project's lint/typecheck (`tsc --noEmit`, `eslint`) plus any tests. Full production build is optional if a typecheck passes.
       - Backend source changed → compile/typecheck + backend tests for the affected module.
       - Mixed → cover each area with the lightest check that applies.

    Do NOT run a full `npm run build` / `vite build` / `webpack` by default — they are slow and memory-hungry. Only run one if the change is frontend source code AND `tsc --noEmit` is unavailable or insufficient.

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

    case Golem.Runner.run_sub_agent(goal, "Adversarial verification. Be thorough, be strict, trust nothing. Report only, do not fix.", 0) do
      {:ok, %{success: true}} -> :ok
      {:ok, %{success: false, summary: summary}} -> {:error, summary}
      {:error, :max_steps_reached} -> {:error, "Verification agent hit step limit (likely many issues)"}
      {:error, reason} -> {:error, "Verification agent crashed: #{inspect(reason)}"}
    end
  end

end
