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

    ## Required checks (run ALL of these)

    1. **Discover the project**: Use `list_directory`, `glob`, and `read_file` to find the project structure and determine how to build and test it.
    2. **Test suite**: Run the project's test suite. Report any failures verbatim.
    3. **Clean build**: Run a clean compile/build. Report ALL warnings.
    4. **Unused code scan**: `grep -rn` for unused imports, dead functions, TODO/FIXME/HACK placeholders, and commented-out code blocks in recently modified files.

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
