defmodule Golem.Runner.SubAgent do
  @moduledoc """
  Sub-agent execution. Spawned via the `sub_agent` /
  `parallel_sub_agents` tools, or by the verify pass.

  Sub-agents skip Opus planning — they execute directly with Sonnet
  inside the parent's executor loop. They inherit the parent's
  message history (fork model) so prompt cache hits carry over and
  the sub-agent has full context, then a directive message scopes
  it to a specific sub-task.

  Buffered mode (used by `parallel_sub_agents`) accumulates tool
  output in the worker's process dict so concurrent sub-agents'
  TUI output never interleaves; the full block prints atomically
  on completion.
  """

  require Logger

  @sub_agent_max_steps 50

  defp output, do: Golem.Output.current()

  @doc """
  Run a sub-agent with its own context. Returns the same shape as
  `Golem.run/2`, plus a `:files` key listing files modified during
  the sub-agent's run.
  """
  def run(goal, context, parent_depth, parent_state \\ nil, opts \\ []) do
    depth = parent_depth + 1
    prefix = Golem.Runner.depth_prefix(depth)
    display_name = Keyword.get(opts, :display_name)
    max_steps = Keyword.get(opts, :max_steps, @sub_agent_max_steps)
    buffered? = Keyword.get(opts, :buffered, false)

    # Buffered mode: accumulate tool entries in the Task's process
    # dict instead of streaming them through the TUI. Used by
    # parallel_sub_agents so 5+ concurrent agents' tool calls don't
    # interleave under whichever header was printed last.
    if buffered?, do: Process.put(:golem_sub_agent_buffer, [])

    if parent_depth == 0 and not buffered?, do: output().sub_agent_start(goal, display_name)

    Golem.Events.emit(:sub_agent_start, %{
      depth: depth,
      goal: String.slice(goal, 0, 500),
      display_name: display_name,
      has_context: context != nil and context != ""
    })

    # Build directive message for the sub-agent
    context_section = if context && context != "", do: "\n\n## Additional Context\n\n#{context}", else: ""

    directive = """
    ## STOP — Sub-Agent Handoff

    The conversation above is your parent agent's context, provided so you can read it like reference material. You are NOT the parent agent. You are NOT continuing the parent's work. You have ONE narrow task, defined below.

    ## Your task

    #{goal}#{context_section}

    ## Hard rules

    1. **Do EXACTLY what the task says — nothing else.** If the task says "find and read X", you grep, you read_file, you call `done`. You do NOT also: back up files, run builds, modify code, check related files, or continue any work the parent was doing.
    2. **Read the task as a literal scope contract.** "Find X" does not include "and fix it". "Read Y" does not include "and verify it builds". If the task doesn't say to write or modify a file, DO NOT write or modify any file.
    3. **Step budget: aim for under 15 steps. Hard cap: #{max_steps}.** If you're past 15 steps and not close to calling `done`, you're off-track — narrow your approach.
    4. **Skip "verify every step" instincts unless your task is to build/modify code.** No `php -l`, no `vue-tsc`, no `npm run`, no test runs, unless the task explicitly involves changing code that needs that verification.
    5. **Call `done` the moment you have what the task asked for.** For read/find/check tasks, the `summary` IS the answer (file path, function signature, the thing you found). Don't keep exploring "just to be thorough".
    6. Do NOT spawn sub-agents yourself.
    """

    # Fork model: inherit parent's messages for full context + prompt cache reuse
    # Fall back to fresh context if no parent state (e.g., tests, direct calls)
    {messages, system, errors} =
      if parent_state && parent_state.messages != [] do
        forked = parent_state.messages ++ [
          %{role: "assistant", content: "I'll delegate this to a sub-agent."},
          %{role: "user", content: directive}
        ]
        # Use parent's system prompt for cache hits
        parent_errors = Map.get(parent_state, :errors, [])
        agents_md = Map.get(parent_state, :agents_md)
        sys = Golem.Prompt.executor_system(parent_errors, agents_md)
        {forked, sys, parent_errors}
      else
        fresh = [%{role: "user", content: directive}]
        {fresh, Golem.Prompt.sub_agent_system(), []}
      end

    state = %{
      goal: goal,
      plan: Map.get(parent_state || %{}, :plan),
      messages: messages,
      step: 0,
      max_steps: max_steps,
      depth: depth,
      prefix: prefix,
      history: [],
      costs: %{total_dollars: 0.0},
      errors: errors,
      phase_costs: [],
      last_completed: 0
    }

    result = Golem.Runner.loop(state, system)

    # Pull the real step count out of the summary (the loop runs a
    # recursive immutable state, so the closure-captured `state.step`
    # is forever 0). On :max_steps_reached the loop now carries the
    # step count in the error tuple, so capped sub-agents render as
    # "50 steps" instead of misleading "0 steps".
    {success, steps} = case result do
      {:ok, %{success: s} = summary} -> {s, Map.get(summary, :steps, 0)}
      {:error, :max_steps_reached, step} -> {false, step}
      _ -> {false, 0}
    end

    # Report sub-agent completion to TUI. In buffered mode the entire
    # block (header + tool lines + footer) is printed atomically here
    # so concurrent sub-agents' output never interleaves; in streaming
    # mode the header was printed at start and only the trailing
    # "done" footer is emitted now.
    cond do
      buffered? ->
        entries = Process.delete(:golem_sub_agent_buffer) |> List.wrap() |> Enum.reverse()
        label = display_name || goal
        output().sub_agent_block(label, entries, success, steps)

      parent_depth == 0 ->
        output().sub_agent_result(goal, steps, success)

      true ->
        :ok
    end

    Golem.Events.emit(:sub_agent_end, %{
      depth: depth,
      goal: String.slice(goal, 0, 500),
      success: match?({:ok, %{success: true}}, result),
      steps: steps,
      summary: case result do
        {:ok, %{summary: s}} -> String.slice(s || "", 0, 500)
        {:error, reason} -> "error: #{inspect(reason)}"
        {:error, reason, _step} -> "error: #{inspect(reason)}"
        _ -> ""
      end
    })

    # Extract files from the sub-agent for parent awareness
    # Costs are already in summary.costs from the loop
    case result do
      {:ok, summary} ->
        files = Golem.Runner.extract_modified_files(state)
        {:ok, Map.put(summary, :files, files)}

      other ->
        other
    end
  end
end
