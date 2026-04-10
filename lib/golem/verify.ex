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
  Run programmatic verification (compile + test) in the container.

  Returns:
  - `{:ok, project_path}` — all checks passed
  - `{:ok, nil}` — no recognizable project found (skip verification)
  - `{:error, issues_text}` — one or more checks failed
  """
  def run_checks do
    case detect_project() do
      {type, path} ->
        Logger.info("[verify] Detected #{type} project at #{path}")
        commands = commands_for(type, path)
        run_and_check(commands, path)

      :unknown ->
        Logger.info("[verify] No recognizable project found, skipping programmatic checks")
        {:ok, nil}
    end
  end

  @doc """
  Spawn a fresh sub-agent to do a thorough quality review.

  The sub-agent has zero prior context — no fatigue, no assumptions.
  It only reports issues; it does NOT fix them (the main agent will).

  Returns `:ok` or `{:error, issues_text}`.
  """
  def run_agent(project_path) do
    goal = """
    You are an adversarial verification agent. Your job is to FIND PROBLEMS in the project at #{project_path}. Do NOT fix anything — report only.

    ## Required checks (run ALL of these)

    1. **Test suite**: Run the full test suite. Report any failures verbatim.
    2. **Clean build**: Run a clean compile/build. Report ALL warnings — unused variables, dead code, deprecation warnings.
    3. **Linter**: Run the linter if available (cargo clippy, mix credo, eslint, pylint, go vet). Report all findings.
    4. **Unused code scan**: `grep -rn` for unused imports, dead functions, TODO/FIXME/HACK/unimplemented!() placeholders, and commented-out code blocks.

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

    If you find ANY issues, call `done(success=false)` with a numbered list of every issue.
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

  # --- Project Detection ---

  @markers [
    {"Cargo.toml", :rust},
    {"mix.exs", :elixir},
    {"package.json", :node},
    {"go.mod", :go},
    {"pyproject.toml", :python},
    {"setup.py", :python}
  ]

  defp detect_project do
    Enum.find_value(@markers, :unknown, fn {file, type} ->
      cmd = "find /home/agent -maxdepth 3 -name '#{file}' -type f 2>/dev/null | head -1"

      case Golem.Sandbox.exec(cmd, timeout: 10_000) do
        {:ok, %{output: path, exit_code: 0}} when byte_size(path) > 0 ->
          trimmed = String.trim(path)
          if trimmed != "", do: {type, Path.dirname(trimmed)}, else: nil

        _ ->
          nil
      end
    end)
  end

  # --- Verification Commands ---

  defp commands_for(:rust, path) do
    [
      {"compile", "cd '#{path}' && cargo check 2>&1"},
      {"test", "cd '#{path}' && cargo test 2>&1"}
    ]
  end

  defp commands_for(:elixir, path) do
    [
      {"compile", "cd '#{path}' && mix compile 2>&1"},
      {"test", "cd '#{path}' && mix test 2>&1"}
    ]
  end

  defp commands_for(:node, path) do
    [
      {"build", "cd '#{path}' && npm run build --if-present 2>&1"},
      {"test", "cd '#{path}' && npm test 2>&1"}
    ]
  end

  defp commands_for(:go, path) do
    [
      {"build", "cd '#{path}' && go build ./... 2>&1"},
      {"test", "cd '#{path}' && go test ./... 2>&1"}
    ]
  end

  defp commands_for(:python, path) do
    [
      {"test", "cd '#{path}' && python -m pytest 2>&1"}
    ]
  end

  defp commands_for(_, _), do: []

  # --- Command Execution ---

  defp run_and_check([], path), do: {:ok, path}

  defp run_and_check(commands, path) do
    timeout = Application.get_env(:golem, :command_timeout, 900_000)

    results =
      Enum.map(commands, fn {name, cmd} ->
        Logger.info("[verify] Running #{name}...")

        case Golem.Sandbox.exec(cmd, timeout: timeout) do
          {:ok, %{output: output, exit_code: code}} ->
            {name, truncate_tail(output, 3000), code}

          {:error, {:timeout, partial}} ->
            {name, "Command timed out.\n#{truncate_tail(partial, 1000)}", 1}

          {:error, reason} ->
            {name, inspect(reason), 1}
        end
      end)

    failures = Enum.filter(results, fn {_, _, code} -> code != 0 end)

    if failures == [] do
      {:ok, path}
    else
      issues =
        Enum.map_join(failures, "\n\n", fn {name, output, _code} ->
          "### #{name} failed\n```\n#{output}\n```"
        end)

      {:error, issues}
    end
  end

  defp truncate_tail(text, max) do
    if byte_size(text) > max do
      "...[truncated]\n" <> binary_part(text, byte_size(text) - max, max)
    else
      text
    end
  end
end
