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
    ## Sub-Agent Task

    You are a sub-agent working on a specific task. The conversation above is your parent agent's full context — you know everything it knows.

    Your task: #{goal}#{context_section}

    Rules:
    - Focus ONLY on this task. Do not work on other items from the plan.
    - Do NOT spawn sub-agents yourself.
    - When done, call `done` with a clear summary of what you accomplished and which files you created/modified.
    - You have a limited number of steps. Be efficient.
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
    # is forever 0). For non-:done exits we fall back to 0 — those
    # paths don't surface to sub-agent UI today.
    {success, steps} = case result do
      {:ok, %{success: s} = summary} -> {s, Map.get(summary, :steps, 0)}
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
