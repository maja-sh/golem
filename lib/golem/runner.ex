defmodule Golem.Runner do
  @moduledoc """
  Main autonomous execution loop.

  1. Takes a goal
  2. Creates a plan (Opus)
  3. Executes steps in a loop (Sonnet with tools)
  4. Re-plans when the agent uses the `think` tool
  5. Terminates when done or max steps reached
  """

  require Logger

  defp output, do: Golem.Output.current()

  # Shared module attributes used across multiple sections
  @escalation_steps 5

  @doc """
  Run the agent with the given goal. Blocks until completion.

  Options:
  - :max_steps — override max steps (default from config)
  - :plan — provide a pre-made plan instead of generating one

  Returns {:ok, summary} or {:error, reason}.
  """
  @sub_agent_max_steps 50

  def run(goal, opts \\ []) do
    max_steps = opts[:max_steps] || Application.get_env(:golem, :max_steps, 200)
    depth = opts[:depth] || 0
    run_id = opts[:run_id] || Golem.State.new_run_id()
    prefix = depth_prefix(depth)

    # Initialize TUI first (suppresses console logger)
    if depth == 0, do: output().init_display(run_id, goal)

    # Bind this process to the run so event emissions route to the
    # right events.jsonl.
    if depth == 0, do: Golem.Events.set_run(run_id)

    Golem.Events.emit(:run_start, %{
      goal: goal,
      max_steps: max_steps,
      depth: depth,
      planner_model: Application.get_env(:golem, :planner_model),
      executor_model: Application.get_env(:golem, :executor_model)
    })

    result = do_run(goal, opts, max_steps, depth, prefix, run_id)

    if depth == 0 do
      case result do
        {:ok, %{success: success} = s} -> output().run_complete(success, s.summary)
        {:error, :max_steps_reached} -> output().run_paused(run_id)
        {:error, reason} -> output().run_error(reason)
      end

      output().stop_display()
    end

    case result do
      {:ok, %{success: true} = s} ->
        Golem.Events.emit(:run_end, %{success: true, summary: s.summary, cost: Map.get(s, :costs, %{})})

      {:ok, %{success: false} = s} ->
        Golem.Events.emit(:run_end, %{success: false, summary: s.summary, cost: Map.get(s, :costs, %{})})

      {:error, :max_steps_reached} ->
        Logger.warning("#{prefix}RUN PAUSED — resume: #{run_id}")
        Golem.Events.emit(:run_paused, %{run_id: run_id})

      {:error, reason} ->
        Logger.error("#{prefix}RUN ERROR: #{inspect(reason)}")
        Golem.Events.emit(:run_error, %{reason: inspect(reason)})
    end

    if depth == 0, do: Golem.Events.clear_run()

    result
  end

  @doc """
  Resume a previously paused run.
  """
  def resume(run_id, opts \\ []) do
    case Golem.State.load(run_id) do
      {:ok, saved} ->
        extra_steps = opts[:max_steps] || Application.get_env(:golem, :max_steps, 200)
        new_max = saved.step + extra_steps
        prefix = depth_prefix(saved.depth)

        if saved.depth == 0 do
          output().init_display(run_id, saved.goal)
          output().planning("Resuming from step #{saved.step}...")
          # Restore progress checklist
          progress = Map.get(saved, :progress, [])
          if progress != [], do: output().set_progress(progress)
          Golem.Events.set_run(run_id)
        end

        Golem.Events.emit(:run_resumed, %{from_step: saved.step, new_max: new_max})

        state = %{
          goal: saved.goal,
          plan: saved.plan,
          messages: saved.messages,
          step: saved.step,
          max_steps: new_max,
          depth: saved.depth,
          prefix: prefix,
          history: saved.history,
          costs: Map.get(saved, :costs, %{total_dollars: 0.0}),
          errors: Map.get(saved, :errors, []),
          agents_md: Map.get(saved, :agents_md),
          phase_costs: Map.get(saved, :phase_costs, []),
          last_completed: Map.get(saved, :last_completed, 0),
          run_id: run_id
        }

        # Restore verify commands from saved state (or re-extract from plan)
        verify_commands = Map.get(saved, :verify_commands, nil) || Golem.PlanParser.extract_verify_commands(saved.plan)
        :persistent_term.put(:golem_verify_commands, verify_commands)

        # Inject resume message and any custom message from --message flag
        inject = opts[:inject_message]
        state =
          cond do
            Map.get(saved, :progress, []) == [] and state.messages != [] ->
              msg = "[System] Run resumed. Use `update_progress` to set your current progress checklist before continuing."
              msg = if inject, do: msg <> "\n\n#{inject}", else: msg
              %{state | messages: state.messages ++ [%{role: "user", content: msg}]}

            inject ->
              %{state | messages: state.messages ++ [%{role: "user", content: "[System] #{inject}"}]}

            true ->
              state
          end

        system = Golem.Prompt.executor_system(state.errors)
        result = loop(state, system)

        if saved.depth == 0 do
          case result do
            {:ok, %{success: success} = s} -> output().run_complete(success, s.summary)
            {:error, :max_steps_reached} -> output().run_paused(run_id)
            {:error, reason} -> output().run_error(reason)
          end
          output().stop_display()
        end

        case result do
          {:ok, %{success: true} = s} ->
            Golem.Events.emit(:run_end, %{success: true, summary: s.summary, cost: Map.get(s, :costs, %{})})

          {:ok, %{success: false} = s} ->
            Golem.Events.emit(:run_end, %{success: false, summary: s.summary, cost: Map.get(s, :costs, %{})})

          {:error, :max_steps_reached} ->
            Logger.warning("#{prefix}RUN PAUSED — resume: #{run_id}")
            Golem.Events.emit(:run_paused, %{run_id: run_id})

          {:error, reason} ->
            Logger.error("#{prefix}RUN ERROR: #{inspect(reason)}")
            Golem.Events.emit(:run_error, %{reason: inspect(reason)})
        end

        if saved.depth == 0, do: Golem.Events.clear_run()

        result

      {:error, reason} ->
        Logger.error("Failed to load run #{run_id}: #{inspect(reason)}")
        {:error, {:load_failed, reason}}
    end
  end

  defp do_run(goal, opts, max_steps, depth, prefix, run_id) do
    plan_result =
      case opts[:plan] do
        nil ->
          if depth == 0, do: output().planning()
          Logger.info("#{prefix}Planning with Opus...")
          create_plan(goal, opts)

        plan ->
          {:ok, plan, %{total_dollars: 0.0}}
      end

    case plan_result do
      {:ok, plan, planner_costs} ->
        if depth == 0, do: output().plan_created(plan)

        verify_commands = Golem.PlanParser.extract_verify_commands(plan)

        phases = Regex.scan(~r/^## /m, plan) |> length()
        step_count = Regex.scan(~r/- \[ \]/m, plan) |> length()
        Golem.Events.emit(:plan_created, %{
          depth: depth,
          plan: plan,
          phases: phases,
          step_count: step_count,
          verify_count: map_size(verify_commands),
          planner_cost: Map.get(planner_costs, :total_dollars, 0.0)
        })
        :persistent_term.put(:golem_verify_commands, verify_commands)
        :persistent_term.put(:golem_completed_sub_agents, %{})

        # Fold any pre-flight spend (Jira evaluator call) into the
        # run's cost total so the TUI / budget / final summary reflect
        # what actually hit the Anthropic bill.
        initial_cost = opts[:initial_cost] || 0.0

        starting_costs =
          Map.update(planner_costs, :total_dollars, initial_cost, &(&1 + initial_cost))

        state = %{
          goal: goal,
          plan: plan,
          messages: [],
          step: 0,
          max_steps: max_steps,
          depth: depth,
          prefix: prefix,
          history: [],
          costs: starting_costs,
          errors: [],
          agents_md: opts[:agents_md],
          phase_costs: [],
          last_completed: 0,
          run_id: run_id
        }

        system = Golem.Prompt.executor_system([])
        attachment_blocks = opts[:attachment_blocks] || []
        initial_content = Golem.Prompt.initial_message(goal, plan, attachment_blocks)
        state = %{state | messages: [%{role: "user", content: initial_content}]}

        loop(state, system)

      {:error, reason} ->
        Logger.error("#{prefix}Planning failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Run a sub-agent with its own context. Used by the sub_agent tool.
  Skips Opus planning — sub-agents execute directly with Sonnet.

  Uses fork model: sub-agent inherits the parent's full message history
  for context awareness and prompt cache reuse.
  """
  def run_sub_agent(goal, context, parent_depth, parent_state \\ nil, opts \\ []) do
    depth = parent_depth + 1
    prefix = depth_prefix(depth)
    display_name = Keyword.get(opts, :display_name)
    max_steps = Keyword.get(opts, :max_steps, @sub_agent_max_steps)
    if parent_depth == 0, do: output().sub_agent_start(goal, display_name)

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

    result = loop(state, system)

    # Report sub-agent completion to TUI
    if parent_depth == 0 do
      {success, steps} = case result do
        {:ok, %{success: s}} -> {s, state.step}
        _ -> {false, state.step}
      end
      output().sub_agent_result(goal, steps, success)
    end

    Golem.Events.emit(:sub_agent_end, %{
      depth: depth,
      goal: String.slice(goal, 0, 500),
      success: match?({:ok, %{success: true}}, result),
      steps: state.step,
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
        files = extract_modified_files(state)
        {:ok, Map.put(summary, :files, files)}

      other ->
        other
    end
  end

  defp extract_modified_files(%{history: history}) do
    history
    |> Enum.filter(fn {tool, _, _} -> tool in ["write_file", "edit_file"] end)
    |> Enum.map(fn {_, input, _} -> to_string(input) end)
    |> Enum.uniq()
  end

  defp extract_modified_files(_), do: []

  # --- Plan Creation ---

  defp create_plan(goal, opts) do
    explore_model = Application.get_env(:golem, :executor_model)   # Sonnet for exploration
    plan_model = Application.get_env(:golem, :planner_model)       # Opus for final plan
    max_tokens = Application.get_env(:golem, :planner_max_tokens, 4096)
    thinking_budget = Application.get_env(:golem, :thinking_budget, 10_000)
    tools = Golem.Tools.for_planner()
    costs = %{total_dollars: 0.0}

    # Read AGENTS.md / CLAUDE.md from project roots for planner context
    agents_md_content = read_project_agents_md(opts[:agents_md])
    system = Golem.Prompt.planner_system(:explore, agents_md_content)

    messages = [
      %{role: "user", content: "Create a plan for this goal:\n\n#{goal}"}
    ]

    planner_ctx = %{seen_agents_md: MapSet.new(), explore_model: explore_model, plan_model: plan_model}
    planner_loop(messages, explore_model, max_tokens, thinking_budget, tools, system, costs, planner_ctx, 1)
  end

  # Read AGENTS.md content that was already built by the integration module
  defp read_project_agents_md(nil), do: nil
  defp read_project_agents_md(agents_md) when is_binary(agents_md), do: agents_md

  defp planner_loop(messages, model, max_tokens, thinking_budget, tools, system, costs, ctx, step) do
    max = Application.get_env(:golem, :planner_max_steps, 75)

    if step > max do
      {:error, :planner_max_steps}
    else
      planner_step(messages, model, max_tokens, thinking_budget, tools, system, costs, ctx, step)
    end
  end

  defp planner_step(messages, model, max_tokens, thinking_budget, tools, system, costs, ctx, step) do

    result = Golem.Claude.call(messages,
      model: model,
      max_tokens: max_tokens,
      system: system,
      tools: tools,
      thinking_budget: thinking_budget
    )

    case result do
      {:ok, %{tool_use: tool_calls} = response} when tool_calls != [] ->
        costs = accumulate_costs(costs, response.usage, model)
        output().update_cost("$#{format_cost(costs)}")

        # Show planner text in TUI
        if response.text, do: output().agent_text(response.text)

        # Check if create_plan was called — Sonnet signals it's done exploring
        case Enum.find(tool_calls, &(&1.name == "create_plan")) do
          %{input: %{"plan" => sonnet_plan}} ->
            # Hand off to Opus for the final plan, using Sonnet's draft as input
            output().planning("Creating plan with Opus...")
            finalize_plan(messages, sonnet_plan, ctx.plan_model, max_tokens, thinking_budget, system, costs)

          nil ->
            # Execute read-only tools and continue the loop
            {tool_results, ctx} = execute_planner_tools(tool_calls, ctx)

            # Build the assistant message with tool_use blocks
            assistant_content =
              (if response.text, do: [%{type: "text", text: response.text}], else: []) ++
              Enum.map(tool_calls, fn tc ->
                %{type: "tool_use", id: tc.id, name: tc.name, input: tc.input}
              end)

            # Build tool_result messages
            result_content =
              Enum.map(tool_results, fn {id, result_text} ->
                %{type: "tool_result", tool_use_id: id, content: result_text}
              end)

            updated = messages ++ [
              %{role: "assistant", content: assistant_content},
              %{role: "user", content: result_content}
            ]

            planner_loop(updated, model, max_tokens, thinking_budget, tools, system, costs, ctx, step + 1)
        end

      # No tool calls — planner responded with text only (legacy behavior)
      {:ok, %{text: text} = response} when is_binary(text) ->
        costs = accumulate_costs(costs, response.usage, model)
        output().update_cost("$#{format_cost(costs)}")
        {:ok, text, costs}

      {:ok, _} ->
        {:error, :no_plan_text}

      {:error, reason} when reason in [:planner_max_steps] ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # One Opus call with full context to produce the final plan
  defp finalize_plan(messages, sonnet_plan, model, max_tokens, thinking_budget, system, costs) do
    final_messages = messages ++ [
      %{role: "user", content: """
      The exploration phase is complete. Here is a draft plan based on what was found:

      #{sonnet_plan}

      Review the exploration above and produce the final plan. Refine, reorder, or restructure as needed. \
      Return the plan as a markdown checklist grouped into phases. Include verify commands where applicable.
      """}
    ]

    case Golem.Claude.call(final_messages,
           model: model,
           max_tokens: max_tokens,
           system: system,
           thinking_budget: thinking_budget
         ) do
      {:ok, %{text: text} = response} when is_binary(text) ->
        costs = accumulate_costs(costs, response.usage, model)
        output().update_cost("$#{format_cost(costs)}")
        {:ok, text, costs}

      {:ok, _} ->
        {:error, :no_plan_text}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_planner_tools(tool_calls, ctx) do
    # Show all tool calls in TUI first
    Enum.each(tool_calls, fn tc ->
      output().tool_call(tc.name, summarize_planner_input(tc))
    end)

    # Execute all read-only tools in parallel
    results =
      tool_calls
      |> Task.async_stream(fn tc ->
        start = System.monotonic_time(:millisecond)
        {_tag, result_text} = Golem.ToolHandler.execute(tc, 0)
        elapsed = System.monotonic_time(:millisecond) - start

        display = String.slice(result_text, 0, 200)
        output().tool_result(tc.name, summarize_planner_input(tc), display, elapsed, nil)

        # Collect file paths from tool calls for AGENTS.md discovery
        paths = extract_paths_from_tool(tc)
        {tc.id, result_text, paths}
      end, max_concurrency: 8, timeout: 60_000)
      |> Enum.map(fn {:ok, result} -> result end)

    # Discover AGENTS.md files in directories touched by these tool calls
    all_paths = Enum.flat_map(results, fn {_id, _text, paths} -> paths end)
    {agents_md_results, ctx} = discover_agents_md(all_paths, ctx)

    # Append discovered AGENTS.md contents to the last tool result
    results =
      if agents_md_results != "" do
        results
        |> Enum.map(fn {id, text, _paths} -> {id, text} end)
        |> List.update_at(-1, fn {id, text} ->
          {id, text <> "\n\n--- Auto-discovered project documentation ---\n" <> agents_md_results}
        end)
      else
        Enum.map(results, fn {id, text, _paths} -> {id, text} end)
      end

    {results, ctx}
  end

  defp extract_paths_from_tool(%{name: "read_file", input: %{"path" => path}}), do: [path]
  defp extract_paths_from_tool(%{name: "grep", input: %{"path" => path}}) when is_binary(path), do: [path]
  defp extract_paths_from_tool(%{name: "glob", input: %{"path" => path}}) when is_binary(path), do: [path]
  defp extract_paths_from_tool(%{name: "list_directory", input: %{"path" => path}}), do: [path]
  defp extract_paths_from_tool(_), do: []

  defp discover_agents_md(paths, ctx) do
    # Collect all unique directories from the paths
    dirs =
      paths
      |> Enum.flat_map(&ancestor_dirs/1)
      |> Enum.uniq()

    # Check each directory for AGENTS.md or CLAUDE.md
    new_docs =
      dirs
      |> Enum.flat_map(fn dir ->
        ["AGENTS.md", "CLAUDE.md"]
        |> Enum.map(fn name -> "#{dir}/#{name}" end)
        |> Enum.reject(&MapSet.member?(ctx.seen_agents_md, &1))
      end)
      |> Task.async_stream(fn path ->
        case Golem.Sandbox.exec("cat #{path} 2>/dev/null", timeout: 5_000) do
          {:ok, %{exit_code: 0, output: content}} when byte_size(content) > 0 ->
            {path, content}
          _ ->
            nil
        end
      end, max_concurrency: 8, timeout: 10_000)
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.reject(&is_nil/1)

    # Update seen set
    new_seen = Enum.reduce(new_docs, ctx.seen_agents_md, fn {path, _}, acc -> MapSet.put(acc, path) end)

    # Also mark checked-but-missing paths as seen to avoid rechecking
    all_checked = dirs |> Enum.flat_map(fn dir -> ["#{dir}/AGENTS.md", "#{dir}/CLAUDE.md"] end)
    new_seen = Enum.reduce(all_checked, new_seen, &MapSet.put(&2, &1))

    content =
      new_docs
      |> Enum.map(fn {path, content} ->
        Golem.Events.emit(:agents_md_discovered, %{path: path})
        "## #{path}\n\n#{String.trim(content)}"
      end)
      |> Enum.join("\n\n")

    {content, %{ctx | seen_agents_md: new_seen}}
  end

  defp ancestor_dirs(path) do
    dir = Path.dirname(path)
    if dir == "/" or dir == "." do
      []
    else
      [dir | ancestor_dirs(dir)]
    end
  end

  defp summarize_planner_input(%{name: "read_file", input: input}), do: input["path"] || ""
  defp summarize_planner_input(%{name: "list_directory", input: input}), do: input["path"] || ""
  defp summarize_planner_input(%{name: "glob", input: input}), do: input["pattern"] || ""
  defp summarize_planner_input(%{name: "grep", input: input}), do: "#{input["pattern"]} #{input["path"] || ""}"
  defp summarize_planner_input(%{name: name}), do: name

  defp replan(goal, current_plan, reasoning, recent_history) do
    model = Application.get_env(:golem, :planner_model)
    max_tokens = Application.get_env(:golem, :planner_max_tokens, 4096)
    thinking_budget = Application.get_env(:golem, :thinking_budget, 10_000)

    message = Golem.Prompt.replan_message(goal, current_plan, reasoning, recent_history)

    messages = [
      %{role: "user", content: message}
    ]

    case Golem.Claude.call(messages,
           model: model,
           max_tokens: max_tokens,
           system: Golem.Prompt.planner_system(),
           thinking_budget: thinking_budget
         ) do
      {:ok, %{text: text}} when is_binary(text) -> {:ok, text}
      {:ok, _} -> {:error, :no_plan_text}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Main Loop ---

  defp loop(%{step: step, max_steps: max, prefix: prefix} = state, _system) when step >= max do
    Logger.warning("#{prefix}Hit max steps (#{max}). Saving state...")
    if run_id = Map.get(state, :run_id), do: Golem.State.save(run_id, state)
    {:error, :max_steps_reached}
  end

  defp loop(state, _system) do
    # Check cost budget (only at depth 0)
    max_cost = Application.get_env(:golem, :max_cost, nil)
    current_cost = Map.get(state.costs, :total_dollars, 0.0)

    if state.depth == 0 and max_cost != nil and current_cost >= max_cost do
      Logger.warning("#{state.prefix}Cost budget reached ($#{format_cost(state.costs)} >= $#{max_cost}). Saving state...")
      if run_id = Map.get(state, :run_id), do: Golem.State.save(run_id, state)
      output().run_paused(Map.get(state, :run_id, "unknown"))
      {:error, :budget_exceeded}
    else
      do_loop(state)
    end
  end

  defp do_loop(state) do
    step = state.step + 1
    p = state.prefix
    if run_id = Map.get(state, :run_id), do: Process.put(:golem_run_id, run_id)
    Process.put(:golem_parent_state, state)
    costs = Map.get(state, :costs, %{total_dollars: 0.0})
    errors = Map.get(state, :errors, [])
    cost_str = "$#{format_cost(costs)}"
    if state.depth == 0, do: output().step_header(step, state.max_steps, cost_str)

    Golem.Events.emit(:step, %{
      step: step,
      depth: state.depth,
      max_steps: state.max_steps,
      cost: Map.get(costs, :total_dollars, 0.0)
    })

    # Rebuild system prompt with current error memory and AGENTS.md
    agents_md = Map.get(state, :agents_md)
    system = Golem.Prompt.executor_system(errors, agents_md)

    # Escalate to Opus when stuck, drop back after a few steps
    model =
      if Map.get(state, :escalated_until, 0) > step do
        Application.get_env(:golem, :planner_model)
      else
        Application.get_env(:golem, :executor_model)
      end

    max_tokens = Application.get_env(:golem, :executor_max_tokens, 8000)
    thinking_budget = Application.get_env(:golem, :thinking_budget, 10_000)
    tools = Golem.Tools.for_depth(state.depth)

    # Microcompact: clear bulky tool results from older messages
    messages = microcompact(state.messages)

    # Snip: cheap middle-out removal before expensive LLM summary
    messages = snip_messages(messages)

    # Trim: full LLM summary as last resort
    messages = trim_messages(messages)

    # Append fresh per-turn runtime state as a system-reminder.
    # Built from current state, NOT appended to state.messages, so it
    # never gets persisted or compacted — rebuilt each turn.
    messages = maybe_append_system_reminder(messages, state)

    llm_start = System.monotonic_time(:millisecond)

    result = Golem.Claude.call(messages,
      model: model,
      max_tokens: max_tokens,
      system: system,
      tools: tools,
      thinking_budget: thinking_budget
    )

    case result do
      {:ok, %{tool_use: tool_calls} = response} when tool_calls != [] ->
        state = Map.put(state, :api_failures, 0)  # Reset on success
        state = Map.put(state, :no_tool_count, 0)  # Reset no-tool counter
        llm_elapsed = System.monotonic_time(:millisecond) - llm_start
        output_tokens = Map.get(response.usage, :output_tokens, 0)
        input_tokens = Map.get(response.usage, :input_tokens, 0)
        if input_tokens > 0, do: :persistent_term.put(:golem_last_input_tokens, input_tokens)

        Golem.Events.emit(:api_call, %{
          step: step,
          depth: state.depth,
          model: model,
          elapsed_ms: llm_elapsed,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cache_read: Map.get(response.usage, :cache_read, 0),
          cache_create: Map.get(response.usage, :cache_create, 0),
          tool_count: length(tool_calls)
        })

        if response.text do
          if state.depth == 0, do: output().agent_text(response.text)
          Golem.Events.emit(:agent_text, %{step: step, depth: state.depth, text: response.text})
        end

        if is_nil(response.text) and state.depth == 0 do
          count = length(tool_calls)
          if count > 1 do
            output().agent_text("Running #{count} actions (#{Golem.TUI.format_elapsed(llm_elapsed)})")
          end
        end

        costs = accumulate_costs(costs, response.usage, model)
        if state.depth == 0, do: output().update_tokens(output_tokens)

        # Execute all tool calls, stopping early on done/think_replan
        Process.delete(:golem_sub_agent_costs)
        tool_result = execute_tool_calls(tool_calls, state.depth, state)

        # Merge any sub-agent costs into this run's total
        sub_costs = Process.get(:golem_sub_agent_costs, 0.0)
        costs = Map.update!(costs, :total_dollars, &(&1 + sub_costs))

        case tool_result do
          {:done, summary, executed} ->
            messages = append_multi_tool_exchange(messages, response, executed)
            state = %{state | messages: messages, step: step, costs: costs, history: update_history(state.history, executed)}

            case maybe_verify(summary, state) do
              {:accept, state} ->
                # Promote all progress items to completed on verified success
                if summary.success and state.depth == 0 do
                  progress = :persistent_term.get(:golem_progress, [])
                  completed = Enum.map(progress, &%{&1 | status: :completed})
                  :persistent_term.put(:golem_progress, completed)
                  output().set_progress(completed)
                end
                log_phase_costs(state)
                maybe_save(state)
                :persistent_term.put(:golem_verify_commands, %{})
                {:ok, Map.put(summary, :costs, costs)}

              {:reject, state} ->
                maybe_save(state)
                loop(state, system)
            end

          {:think_replan, reasoning, executed} ->
            messages = append_multi_tool_exchange(messages, response, executed)
            state = %{state | messages: messages, step: step, costs: costs, history: update_history(state.history, executed)}
            last_tc = List.last(executed) |> elem(0)
            handle_replan(state, system, step, last_tc, reasoning)

          {:continue, executed} ->
            messages = append_multi_tool_exchange(messages, response, executed)
            messages = maybe_inject_review(messages, executed)
            {messages, escalated_until} = maybe_inject_stuck_warning(messages, executed, state)
            messages = maybe_inject_file_size_warning(messages, executed)
            messages = maybe_inject_search_nudge(messages, executed, state)
            new_errors = extract_errors(executed)
            errors = (errors ++ new_errors) |> Enum.uniq() |> Enum.take(-20)
            {phase_costs, last_completed} = track_phase_costs(executed, costs, state)
            messages = maybe_inject_progress_silence_nudge(messages, state, step)
            state = %{state | messages: messages, step: step, costs: costs, errors: errors,
                       phase_costs: phase_costs, last_completed: last_completed,
                       history: update_history(state.history, executed)}
            state = Map.put(state, :escalated_until, escalated_until)
            # Track consecutive think-only turns
            {messages, consecutive_thinks, escalated_until} = maybe_inject_think_warning(state.messages, executed, state)
            state = %{state | messages: messages}
            state = Map.put(state, :consecutive_thinks, consecutive_thinks)
            state = Map.put(state, :escalated_until, escalated_until)
            {messages, consecutive_drifts} = maybe_inject_drift_warning(state)
            state = %{state | messages: messages}
            state = Map.put(state, :consecutive_drifts, consecutive_drifts)
            maybe_save(state)
            loop(state, system)
        end

      {:ok, %{text: text, tool_use: []} = response} ->
        text = text || ""  # Guard against nil text from API
        no_tool_count = Map.get(state, :no_tool_count, 0) + 1
        Golem.Events.emit(:no_tool_response, %{step: step, depth: state.depth, count: no_tool_count, text: String.slice(text, 0, 500)})
        costs = accumulate_costs(costs, response.usage, model)
        input_tokens = Map.get(response.usage, :input_tokens, 0)
        if input_tokens > 0, do: :persistent_term.put(:golem_last_input_tokens, input_tokens)
        if state.depth == 0, do: output().update_tokens(Map.get(response.usage, :output_tokens, 0))

        nudge =
          cond do
            no_tool_count >= 8 ->
              "[System] You have responded #{no_tool_count} times without using a tool. This is a critical failure. Call `think(request_replan: true)` NOW to get a new plan, or call `done` to finish."
            no_tool_count >= 5 ->
              "[System] WARNING: #{no_tool_count} consecutive responses without a tool call. Escalating to a stronger model. You MUST use a tool NOW — `shell`, `write_file`, `edit_file`, `think`, or `done`. Text-only responses are not acceptable."
            no_tool_count >= 3 ->
              "[System] You have responded #{no_tool_count} times without using any tool. You MUST use a tool on your next response. If unsure what to do, use `think` to reason about it, or `done` if the goal is achieved."
            true ->
              "Continue executing the plan. Use a tool for your next action, or use `done` if the goal is achieved."
          end

        escalated_until =
          if no_tool_count >= 5,
            do: step + @escalation_steps,
            else: Map.get(state, :escalated_until, 0)

        messages = state.messages ++ [
          %{role: "assistant", content: text},
          %{role: "user", content: nudge}
        ]
        state = %{state | messages: messages, step: step, costs: costs}
        state = Map.put(state, :no_tool_count, no_tool_count)
        state = Map.put(state, :escalated_until, escalated_until)
        loop(state, system)

      {:error, reason} ->
        Logger.error("#{p}  Claude API error: #{inspect(reason)}")
        api_failures = Map.get(state, :api_failures, 0) + 1

        if api_failures >= 3 do
          # 3 consecutive API failures — give up
          Logger.error("#{p}  #{api_failures} consecutive API failures — stopping")
          {:error, reason}
        else
          # Wait and retry — overloads and transient errors can recover
          wait = min(60_000, 10_000 * api_failures)
          Logger.warning("#{p}  Waiting #{div(wait, 1000)}s before retry (attempt #{api_failures}/3)")
          if state.depth == 0, do: output().planning("API error — retrying in #{div(wait, 1000)}s...")
          Process.sleep(wait)
          maybe_save(state)
          loop(Map.put(state, :api_failures, api_failures), system)
        end
    end
  end

  # Execute multiple tool calls, running read-only tools concurrently.
  # Partitions calls into batches: consecutive concurrent-safe tools run in
  # parallel, everything else runs serially. Stops early on :done / :think_replan.
  @silent_tools ~w(update_progress)
  @concurrent_safe ~w(read_file glob grep list_directory web_search web_fetch screenshot)

  defp execute_tool_calls(tool_calls, depth, state) do
    batches = partition_batches(tool_calls)
    execute_batches(batches, depth, [], depth == 0, state)
  end

  # Group consecutive concurrent-safe tools into one batch.
  # Each non-concurrent tool is its own batch.
  defp partition_batches([]), do: []

  defp partition_batches(tool_calls) do
    {concurrent, rest} = Enum.split_while(tool_calls, &(&1.name in @concurrent_safe))

    cond do
      concurrent != [] and rest == [] ->
        [concurrent]

      concurrent != [] ->
        [serial_tc | remaining] = rest
        [concurrent, [serial_tc] | partition_batches(remaining)]

      true ->
        [serial_tc | remaining] = tool_calls
        [[serial_tc] | partition_batches(remaining)]
    end
  end

  defp execute_batches([], _depth, executed, _show, _state), do: {:continue, executed}

  defp execute_batches([batch | rest], depth, executed, show, state) do
    if length(batch) > 1 do
      results = execute_concurrent_batch(batch, depth, show, state)
      execute_batches(rest, depth, executed ++ results, show, state)
    else
      [tc] = batch

      case execute_single_tool(tc, depth, show, state) do
        {:done, summary, entry} ->
          {:done, summary, executed ++ [entry]}

        {:think_replan, reasoning, entry} ->
          {:think_replan, reasoning, executed ++ [entry]}

        {:continue, entry} ->
          execute_batches(rest, depth, executed ++ [entry], show, state)
      end
    end
  end

  # Run a batch of read-only tools concurrently using Task.async_stream,
  # so TUI progress lines tick from ○ to ✓ as each tool finishes rather
  # than all-at-once after the slowest.
  defp execute_concurrent_batch(batch, depth, show, state) do
    is_batch_display = show and length(batch) > 1

    if is_batch_display do
      items =
        Enum.map(batch, fn tc ->
          %{id: tc.id, name: tc.name, detail: summarize_input(tc)}
        end)

      output().tool_batch_start(items)
    else
      if show do
        [tc] = batch
        silent = tc.name in @silent_tools
        if not silent, do: output().tool_call(tc.name, summarize_input(tc))
      end
    end

    # Emit tool_call events for every call in the batch up-front, so
    # events.jsonl preserves intent even if a later tool crashes.
    Enum.each(batch, &emit_tool_call_event(&1, depth, state))

    # Capture run_id so Task subprocesses can emit to the right run.
    run_id = Golem.Events.current_run()

    # async_stream with ordered: false gives us results as each task
    # finishes — we emit the per-item "done" event then, for a
    # progressive fill. After the stream we reorder back to the original
    # batch order so downstream (message history, sub-agent status) is
    # deterministic.
    results_by_id =
      batch
      |> Task.async_stream(
        fn tc ->
          if run_id, do: Golem.Events.set_run(run_id)
          start = System.monotonic_time(:millisecond)
          result = Golem.ToolHandler.execute(tc, depth) |> Golem.ToolHandler.truncate_result()
          elapsed = System.monotonic_time(:millisecond) - start
          {tc, result, elapsed}
        end,
        ordered: false,
        max_concurrency: max(length(batch), 1),
        timeout: :infinity
      )
      |> Enum.reduce(%{}, fn {:ok, {tc, result, elapsed} = entry}, acc ->
        if is_batch_display do
          is_error =
            case result do
              {:continue, text} ->
                String.starts_with?(text, "[error]") or String.starts_with?(text, "[exit code")

              _ ->
                false
            end

          outcome = if is_error, do: {:error, elapsed}, else: {:ok, elapsed}
          output().tool_batch_item_done(tc.id, outcome)
        end

        Map.put(acc, tc.id, entry)
      end)

    results = Enum.map(batch, &Map.fetch!(results_by_id, &1.id))

    # Build return entries + handle single-tool display and sub-agent status
    Enum.map(results, fn {tc, result, elapsed} ->
      detail = summarize_input(tc)
      silent = tc.name in @silent_tools

      case result do
        {:continue, text} ->
          is_error = String.starts_with?(text, "[error]") or String.starts_with?(text, "[exit code")

          # Single-tool batch keeps the existing per-tool result rendering.
          # Multi-tool batches already rendered progressively above.
          if show and not silent and length(results) == 1 do
            if is_error,
              do: output().tool_error(tc.name, detail, text),
              else: output().tool_result(tc.name, detail, text, elapsed, nil)
          end

          # Sub-agent: show condensed status line
          if not show and not silent and state do
            emit_sub_agent_status(state, tc.name, detail)
          end

          emit_tool_result_event(tc, depth, state, text, elapsed, is_error)
          {tc, {:text, text}}

        {:continue_with_image, %{text: text, base64: base64}} ->
          if show and not silent and length(results) == 1 do
            output().tool_result(tc.name, detail, text, elapsed, nil)
          end
          if not show and not silent and state do
            emit_sub_agent_status(state, tc.name, detail)
          end
          emit_tool_result_event(tc, depth, state, text, elapsed, false)
          {tc, {:image, text, base64}}
      end
    end)
  end

  # Execute a single tool call (may be any type, including done/think_replan).
  defp execute_single_tool(tc, depth, show, state) do
    detail = summarize_input(tc)
    silent = tc.name in @silent_tools
    if show and not silent, do: output().tool_call(tc.name, detail)

    start = System.monotonic_time(:millisecond)

    emit_tool_call_event(tc, depth, state)

    # Sub-agent: show condensed status in the spinner line
    if not show and not silent and state do
      emit_sub_agent_status(state, tc.name, detail)
    end

    case Golem.ToolHandler.execute(tc, depth) |> Golem.ToolHandler.truncate_result() do
      {:done, summary} ->
        elapsed = System.monotonic_time(:millisecond) - start
        if show, do: output().tool_result(tc.name, detail, summary.summary, elapsed, nil)
        emit_tool_result_event(tc, depth, state, "Goal completed.", elapsed, false)
        {:done, summary, {tc, {:text, "Goal completed."}}}

      {:think_replan, reasoning} ->
        elapsed = System.monotonic_time(:millisecond) - start
        if show, do: output().tool_result(tc.name, detail, "Re-planning...", elapsed, nil)
        emit_tool_result_event(tc, depth, state, "Re-planning requested.", elapsed, false)
        {:think_replan, reasoning, {tc, {:text, "Re-planning requested."}}}

      {:continue, result} ->
        elapsed = System.monotonic_time(:millisecond) - start
        is_error = String.starts_with?(result, "[error]") or String.starts_with?(result, "[exit code")

        if show and not silent do
          if is_error,
            do: output().tool_error(tc.name, detail, result),
            else: output().tool_result(tc.name, detail, result, elapsed, nil)
        end

        emit_tool_result_event(tc, depth, state, result, elapsed, is_error)
        {:continue, {tc, {:text, result}}}

      {:continue_with_image, %{text: text, base64: base64}} ->
        elapsed = System.monotonic_time(:millisecond) - start
        if show and not silent, do: output().tool_result(tc.name, detail, text, elapsed, nil)
        emit_tool_result_event(tc, depth, state, text, elapsed, false)
        {:continue, {tc, {:image, text, base64}}}
    end
  end

  defp emit_tool_call_event(tc, depth, state) do
    Golem.Events.emit(:tool_call, %{
      step: state && state.step,
      depth: depth,
      name: tc.name,
      input: tc.input,
      tool_use_id: tc.id
    })
  end

  defp emit_tool_result_event(tc, depth, state, result, elapsed_ms, is_error) do
    preview = result |> to_string() |> String.slice(0, 500)
    size = byte_size(to_string(result))

    Golem.Events.emit(:tool_result, %{
      step: state && state.step,
      depth: depth,
      name: tc.name,
      tool_use_id: tc.id,
      elapsed_ms: elapsed_ms,
      preview: preview,
      size: size,
      error: is_error
    })
  end

  @sub_agent_silent_tools ~w(think update_progress)

  defp emit_sub_agent_status(state, tool, detail) do
    if tool not in @sub_agent_silent_tools do
      output().sub_agent_status(
        state.goal,
        tool,
        detail,
        state.step,
        state.max_steps
      )
    end
  end

  # Build assistant + user messages for multiple tool calls in one turn
  defp append_multi_tool_exchange(messages, response, executed) do
    # Assistant message: text (if any) + all tool_use blocks
    assistant_content =
      (if response.text, do: [%{type: "text", text: response.text}], else: []) ++
        Enum.map(executed, fn {tc, _result} ->
          %{type: "tool_use", id: tc.id, name: tc.name, input: tc.input}
        end)

    # User message: all tool_result blocks
    tool_results =
      Enum.map(executed, fn {tc, result} ->
        content =
          case result do
            {:text, text} -> maybe_spill_result(text, tc)
            {:image, text, base64} ->
              [
                %{type: "text", text: text},
                %{type: "image", source: %{type: "base64", media_type: "image/png", data: base64}}
              ]
          end

        %{type: "tool_result", tool_use_id: tc.id, content: content}
      end)

    messages ++ [
      %{role: "assistant", content: assistant_content},
      %{role: "user", content: tool_results}
    ]
  end

  defp update_history(history, executed) do
    new_entries =
      Enum.map(executed, fn {tc, result} ->
        input_summary = summarize_input(tc)
        result_summary = case result do
          {:text, text} -> String.slice(text, 0, 200)
          {:image, _, _} -> "[screenshot]"
        end
        {tc.name, input_summary, result_summary}
      end)

    history ++ new_entries
  end

  @max_replans 5

  defp handle_replan(state, system, step, _tool_call, reasoning) do
    replan_count = Map.get(state, :replan_count, 0) + 1

    if replan_count > @max_replans do
      Logger.warning("#{state.prefix}  Replan cap reached (#{replan_count}/#{@max_replans}) — refusing")
      messages =
        state.messages ++
          [%{role: "user", content: "[System] You've replanned #{replan_count - 1} times already — no more replanning allowed. Execute the current plan as-is, or use `done` to report what you've accomplished. Do NOT request another replan."}]

      state = %{state | messages: messages, step: step}
      state = Map.put(state, :replan_count, replan_count)
      loop(state, system)
    else
      if state.depth == 0, do: output().planning("Re-planning with Opus (#{replan_count}/#{@max_replans})...")

      Golem.Events.emit(:replan_start, %{
        step: step,
        depth: state.depth,
        count: replan_count,
        reasoning: String.slice(reasoning || "", 0, 500)
      })

      # Take last 20 history entries for context
      recent = Enum.take(state.history, -20)

      # State already has the tool exchange messages appended from execute_tool_calls
      case replan(state.goal, state.plan, reasoning, recent) do
        {:ok, new_plan} ->

          Golem.Events.emit(:replan_done, %{
            step: step,
            depth: state.depth,
            count: replan_count,
            plan: new_plan
          })

          # Merge new verify commands (additive — keep already-verified items)
          new_verify = Golem.PlanParser.extract_verify_commands(new_plan)
          existing_verify = :persistent_term.get(:golem_verify_commands, %{})
          merged_verify = Map.merge(existing_verify, new_verify)
          :persistent_term.put(:golem_verify_commands, merged_verify)

          messages =
            state.messages ++
              [%{role: "user", content: "## Revised Plan\n\n#{new_plan}\n\nContinue executing from where you left off."}]

          state = %{state | messages: messages, plan: new_plan, step: step}
          state = Map.put(state, :replan_count, replan_count)
          loop(state, system)

        {:error, reason} ->
          Logger.error("#{state.prefix}  Re-planning failed: #{inspect(reason)}")

          messages =
            state.messages ++
              [%{role: "user", content: "Re-planning failed. Continue with the current plan."}]

          state = %{state | messages: messages, step: step}
          state = Map.put(state, :replan_count, replan_count)
          loop(state, system)
      end
    end
  end

  # --- Done Verification ---

  @max_done_rejections 3

  # Only verify top-level successful runs, with a rejection cap.
  defp maybe_verify(summary, state) do
    rejections = Map.get(state, :done_rejections, 0)

    cond do
      not summary.success or state.depth > 0 or rejections >= @max_done_rejections ->
        {:accept, state}

      all_items_system_verified?() ->
        # Every progress item ended in :completed — meaning the plan's
        # per-step `verify:` commands passed independently for each
        # one. The adversarial verifier would re-do solved work with
        # a full sub-agent run (50 steps × Opus). Skip it.
        Logger.info("Verification skipped: all #{item_count()} progress items were system-verified via per-step commands")
        Golem.Events.emit(:verify_skipped, %{reason: "all_items_system_verified", items: item_count()})
        {:accept, state}

      true ->
        Golem.Events.emit(:verify_start, %{attempt: rejections + 1})
        if state.depth == 0, do: output().planning("Running verification agent...")

        case Golem.Verify.run_agent(state.goal) do
          :ok ->
            Golem.Events.emit(:verify_done, %{passed: true})
            {:accept, state}

          {:error, issues} ->
            Golem.Events.emit(:verify_done, %{passed: false, issues: String.slice(issues || "", 0, 1000)})
            reject_done(state, "Verification agent found issues:\n\n#{issues}")
        end
    end
  end

  # All progress items ended :completed iff the per-step verify
  # commands passed for each one. Items the agent marked :done but
  # that didn't have a passing verify command stay :done, not
  # :completed — so :done anywhere means the adversarial agent still
  # has work to do.
  defp all_items_system_verified? do
    items = :persistent_term.get(:golem_progress, [])
    items != [] and Enum.all?(items, &(&1.status == :completed))
  end

  defp item_count, do: :persistent_term.get(:golem_progress, []) |> length()

  defp reject_done(state, issues) do
    rejections = Map.get(state, :done_rejections, 0) + 1

    Logger.warning(
      "#{state.prefix}  Done REJECTED (#{rejections}/#{@max_done_rejections}): " <>
        String.slice(issues, 0, 300)
    )

    if state.depth == 0 do
      output().planning("Verification failed — sending agent back to fix (#{rejections}/#{@max_done_rejections})")
    end

    # List files already created so the agent doesn't recreate them
    created_files = extract_modified_files(state)
    files_section =
      if created_files != [] do
        file_list = Enum.map_join(created_files, "\n", &"- #{&1}")
        """

        ## Files already created/modified (do NOT recreate these)

        #{file_list}
        """
      else
        ""
      end

    messages =
      state.messages ++
        [
          %{
            role: "user",
            content: """
            [System] Your `done` call was REJECTED because verification failed (attempt #{rejections}/#{@max_done_rejections}):

            #{issues}

            IMPORTANT: Only fix the specific issues listed above. Do NOT recreate files or re-run sub-agents for work that is already done. \
            Read existing files with `read_file` first to understand what's already there, then make targeted `edit_file` changes.
            #{files_section}
            Fix ALL of the issues above, then call `done` again.
            """
          }
        ]

    {:reject, state |> Map.put(:messages, messages) |> Map.put(:done_rejections, rejections)}
  end

  # --- Tool-result disk spill ---

  # If a tool produced too much text to safely keep in context, write the
  # full payload to /tmp/golem-spill-<tool_use_id>.txt inside the container
  # and return a preview + reference. Decision + message formatting live
  # in Golem.Runner.Spill (pure, unit-tested); this wrapper handles the
  # side effects.
  defp maybe_spill_result(content, tc) do
    case Golem.Runner.Spill.plan(content, tc) do
      :passthrough ->
        content

      {:spill, path, preview_message} ->
        case Golem.Sandbox.write_file(path, content) do
          :ok ->
            Golem.Events.emit(:tool_result_spilled, %{
              tool_use_id: tc.id,
              tool: tc.name,
              size: byte_size(content),
              spill_path: path
            })

            preview_message

          {:error, reason} ->
            Logger.warning("Tool-result spill failed for #{tc.id}: #{inspect(reason)}")
            content
        end
    end
  end

  # --- Microcompaction ---

  # Selectively compress bulky tool results from older messages.
  # Keeps the last @micro_keep_recent messages untouched. For older messages,
  # replaces large tool_result content with a compact signature that preserves
  # tool name, input summary, success/exit code, and result size. This keeps
  # the model's memory of "what did I already try?" so it doesn't re-run
  # failing commands just because the raw output was cleared.
  @micro_keep_recent 6
  @micro_clearable_tools ~w(shell read_file grep glob web_search web_fetch list_directory browse)
  @micro_min_size 200

  defp microcompact(messages) when length(messages) <= @micro_keep_recent, do: messages

  defp microcompact(messages) do
    split_at = max(0, length(messages) - @micro_keep_recent)
    {old, recent} = Enum.split(messages, split_at)

    # Build a map of tool_use_id → {tool_name, input_summary}
    tool_index = build_tool_index(old)

    Enum.map(old, &microcompact_message(&1, tool_index)) ++ recent
  end

  defp build_tool_index(messages) do
    messages
    |> Enum.filter(&(&1.role == "assistant"))
    |> Enum.flat_map(fn msg ->
      case msg.content do
        blocks when is_list(blocks) ->
          Enum.flat_map(blocks, fn
            %{type: "tool_use", id: id, name: name} = b ->
              [{id, %{name: name, input: Map.get(b, :input, %{})}}]
            %{"type" => "tool_use", "id" => id, "name" => name} = b ->
              [{id, %{name: name, input: Map.get(b, "input", %{})}}]
            _ -> []
          end)
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp microcompact_message(%{role: "user", content: content} = msg, tool_index) when is_list(content) do
    %{msg | content: Enum.map(content, &maybe_clear_tool_result(&1, tool_index))}
  end

  defp microcompact_message(msg, _tool_index), do: msg

  defp maybe_clear_tool_result(%{type: "tool_result", content: content} = block, tool_index) when is_binary(content) do
    id = Map.get(block, :tool_use_id) || Map.get(block, "tool_use_id")
    entry = Map.get(tool_index, id)

    if byte_size(content) > @micro_min_size and entry && entry.name in @micro_clearable_tools do
      %{block | content: build_cleared_signature(entry, content)}
    else
      block
    end
  end

  defp maybe_clear_tool_result(%{"type" => "tool_result", "content" => content} = block, tool_index) when is_binary(content) do
    id = Map.get(block, "tool_use_id")
    entry = Map.get(tool_index, id)

    if byte_size(content) > @micro_min_size and entry && entry.name in @micro_clearable_tools do
      Map.put(block, "content", build_cleared_signature(entry, content))
    else
      block
    end
  end

  defp maybe_clear_tool_result(block, _tool_index), do: block

  # Signature builders moved to Golem.Runner.Compaction for testability.
  defdelegate build_cleared_signature(entry, content), to: Golem.Runner.Compaction
  defdelegate truncate_str(s, max), to: Golem.Runner.Compaction

  # --- Snip Compact ---

  # Cheap middle-out message removal. Drops old message pairs from the middle
  # while keeping head (goal/plan context) and tail (recent work). No LLM call.
  # Runs before full compaction to buy headroom cheaply.
  @snip_token_threshold 100_000
  @snip_keep_head 4
  @snip_keep_tail 30

  defp snip_messages(messages) do
    token_est = estimate_tokens(messages)

    if token_est <= @snip_token_threshold or length(messages) <= @snip_keep_head + @snip_keep_tail do
      messages
    else
      head_count = min(@snip_keep_head, length(messages))
      tail_count = min(@snip_keep_tail, length(messages) - head_count)

      head = Enum.take(messages, head_count)
      tail = Enum.take(messages, -tail_count)

      # Ensure tail starts with a user message (valid message structure)
      tail = drop_leading_assistant_messages(tail)

      middle_removed = length(messages) - head_count - length(tail)

      if middle_removed > 0 do
        # Snip removed messages — invalidate the API-token floor so the next
        # threshold check uses the fresh heuristic estimate.
        :persistent_term.put(:golem_last_input_tokens, 0)
        tokens_freed = token_est - estimate_tokens(head ++ tail)
        Golem.Events.emit(:compaction, %{
          type: "snip",
          messages_removed: middle_removed,
          tokens_freed: tokens_freed
        })

        head ++ [
          %{role: "assistant", content: "I'll continue working on this goal."},
          %{role: "user", content: "[#{middle_removed} earlier messages removed to save context. Recent messages preserved below.]"}
        ] ++ tail
      else
        messages
      end
    end
  end

  defp drop_leading_assistant_messages([%{role: "assistant"} | rest]) do
    drop_leading_assistant_messages(rest)
  end
  defp drop_leading_assistant_messages(messages), do: messages

  # --- Message Management ---

  # Keep conversation manageable. Compact when EITHER:
  # - Message count exceeds @compact_threshold (prevents very long histories)
  # - Estimated tokens exceed @compact_token_threshold (prevents context window overflow)
  #
  # These are set high intentionally — compaction is lossy and should be a last
  # resort, not routine. Microcompaction (clearing old tool results) handles the
  # common case of large outputs without losing conversation structure.
  @compact_threshold 100
  @compact_token_threshold 150_000
  @compact_keep_recent 30

  defp trim_messages(messages) do
    msg_count = length(messages)
    token_est = estimate_tokens(messages)

    if msg_count <= @compact_threshold and token_est <= @compact_token_threshold do
      messages
    else
      reason =
        if token_est > @compact_token_threshold,
          do: "token_threshold",
          else: "message_threshold"

      Golem.Events.emit(:compaction, %{
        type: "full",
        reason: reason,
        message_count: msg_count,
        token_estimate: token_est
      })

      do_trim_messages(messages)
    end
  end

  defp do_trim_messages(messages) do
    # Compaction shrinks the conversation — invalidate the API-token floor
    # so the next threshold check uses the fresh heuristic estimate.
    :persistent_term.put(:golem_last_input_tokens, 0)
    [first | rest] = messages

    # Split into old (to compact) and recent (to keep verbatim)
    keep = min(@compact_keep_recent, length(rest))
    keep = keep - rem(keep, 2)
    split_at = length(rest) - keep
    {old, recent} = Enum.split(rest, split_at)

    # Ensure recent starts with an assistant message (not a user/tool_result)
    # Drop leading user messages that would be orphaned tool_results
    recent = drop_leading_user_messages(recent)

    # Summarize the old messages
    summary = compact_messages(old)

    # Include current progress checklist so the agent doesn't reset it after compaction
    progress_section =
      case :persistent_term.get(:golem_progress, []) do
        [] -> ""
        items ->
          checklist = Enum.map_join(items, "\n", fn item ->
            mark = case item.status do
              :completed -> "x"
              :in_progress -> "~"
              _ -> " "
            end
            "- [#{mark}] #{item.text}"
          end)
          "\n\n## Current Progress Checklist\n\nThis is the AUTHORITATIVE progress state. When you call `update_progress`, preserve these statuses — do NOT reset completed items to pending.\n\n#{checklist}"
      end

    # Rebuild: first message + assistant ack + summary + recent messages
    # The assistant message prevents consecutive user messages (goal + summary)
    [
      first,
      %{role: "assistant", content: "I'll continue working on this goal."},
      %{role: "user", content: "[Conversation summary of earlier steps]\n\n#{summary}#{progress_section}\n\nContinue from where you left off."}
    ] ++ recent
  end

  defp drop_leading_user_messages([%{role: "user"} | rest]) do
    drop_leading_user_messages(rest)
  end
  defp drop_leading_user_messages(messages), do: messages

  # Heuristic estimation moved to Golem.Runner.Compaction. This wrapper
  # adds the per-run floor tracked in persistent_term: we know the prior
  # API call used at least `golem_last_input_tokens` and the message set
  # has only grown since (or been compacted, in which case the floor is
  # reset to 0 by the compactor).
  defp estimate_tokens(messages) do
    heuristic = Golem.Runner.Compaction.estimate_messages_tokens(messages)
    floor_from_api = :persistent_term.get(:golem_last_input_tokens, 0)
    max(heuristic, floor_from_api)
  end

  defp compact_messages(messages) do
    # Extract a structured tool log for the LLM to summarize
    tool_log = extract_tool_log(messages)

    # Use an LLM call for high-quality structured summary
    case llm_compact(tool_log) do
      {:ok, summary} ->
        summary

      {:error, _reason} ->
        # Fall back to raw tool log if LLM fails
        Logger.warning("LLM compaction failed, using raw tool log")
        if byte_size(tool_log) > 10_000 do
          "[#{length(messages)} earlier messages truncated]\n" <>
            String.slice(tool_log, 0, 8_000)
        else
          tool_log
        end
    end
  end

  @compaction_prompt """
  You are summarizing a conversation between an autonomous agent and its tools. \
  The agent is working toward a goal inside a Linux container. This summary will \
  REPLACE the conversation history — it is the ONLY context the agent will have \
  to continue its work. If you omit something, the agent will not know about it.

  Before writing your summary, wrap your analysis in <analysis> tags to organize \
  your thoughts. In your analysis:
  1. Walk through the conversation chronologically
  2. Identify the user's original goal and any scope changes
  3. List every file created or modified with its path
  4. Note every error encountered and how it was fixed
  5. Identify EXACTLY what was being worked on in the most recent messages

  Then write your summary inside <summary> tags with these sections:

  ## Primary Goal
  The original goal and what the agent is trying to achieve overall. Include any \
  clarifications or scope changes that emerged during execution.

  ## Accomplished
  What has been built, installed, or completed so far. List specific files \
  created/modified with their paths. Be thorough — the agent needs to know exactly \
  what exists.

  ## Current State
  Where things stand right now — what's working, what's partially done, what's \
  been tested. Include the state of the build/tests (passing? failing? which ones?).

  ## Key Decisions
  Important choices made (tech stack, architecture, approach) and WHY. The agent \
  needs to remember why it chose approach A over B to avoid revisiting decisions.

  ## Errors & Fixes
  Problems encountered and how they were resolved. Include the error message and \
  the fix so the agent doesn't repeat the same mistake. Only include non-obvious ones.

  ## Current Work
  CRITICAL: Describe EXACTLY what the agent was working on in the most recent \
  messages. Include:
  - The specific task or step from the plan
  - Which file(s) were being modified
  - What was the last action taken
  - What should the agent do NEXT
  Include verbatim quotes from the last few messages if they clarify the task. \
  This section prevents drift — if you get it wrong, the agent will lose track \
  of what it was doing.

  ## Pending Tasks
  Remaining items from the plan that have NOT been started yet. List them in order.

  Keep each section to 3-7 bullet points. Be specific (include file paths, command \
  names, package versions) but concise.

  CRITICAL: Respond with <analysis>...</analysis> followed by <summary>...</summary>. \
  Do NOT use any tools. Do NOT add text outside these tags.
  """

  defp llm_compact(tool_log) do
    # Truncate the tool log if it's massive — we need it to fit in context
    input = if byte_size(tool_log) > 30_000, do: String.slice(tool_log, -30_000, 30_000), else: tool_log

    messages = [
      %{role: "user", content: "Here is the tool call log to summarize:\n\n#{input}"}
    ]

    model = Application.get_env(:golem, :executor_model)

    case Golem.Claude.call(messages,
           model: model,
           max_tokens: 4_000,
           system: @compaction_prompt
         ) do
      {:ok, %{text: text}} when is_binary(text) and text != "" ->
        {:ok, format_compact_summary(text)}

      _ ->
        {:error, :no_summary}
    end
  end

  # Strip the <analysis> scratchpad and extract <summary> content.
  # The analysis improves summary quality but has no value in the final output.
  defp format_compact_summary(text) do
    text = Regex.replace(~r/<analysis>[\s\S]*?<\/analysis>/m, text, "")

    case Regex.run(~r/<summary>([\s\S]*?)<\/summary>/m, text) do
      [_, content] -> String.trim(content)
      nil -> String.trim(text)  # No tags — use as-is
    end
  end

  defp extract_tool_log(messages) do
    messages
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [%{role: "assistant", content: content}, %{role: "user"} = user_msg] ->
        tool_name = extract_tool_name(content)
        result = extract_result_text(user_msg)
        "- [#{tool_name}] → #{String.slice(result, 0, 200)}"

      [%{role: "assistant", content: content}] ->
        text = if is_binary(content), do: content, else: "[tool call]"
        "- Agent: #{String.slice(text, 0, 200)}"

      [%{role: "user", content: content}] ->
        text = if is_binary(content), do: content, else: "[system]"
        "- System: #{String.slice(text, 0, 200)}"

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp extract_tool_name(content) when is_list(content) do
    Enum.find_value(content, "unknown", fn
      %{type: "tool_use", name: name} -> name
      %{"type" => "tool_use", "name" => name} -> name
      _ -> nil
    end)
  end
  defp extract_tool_name(_), do: "text"

  defp extract_result_text(%{content: content}) when is_list(content) do
    Enum.find_value(content, "", fn
      %{content: text} when is_binary(text) -> text
      %{"content" => text} when is_binary(text) -> text
      %{content: blocks} when is_list(blocks) ->
        Enum.find_value(blocks, "", fn
          %{type: "text", text: t} -> t
          %{"type" => "text", "text" => t} -> t
          _ -> nil
        end)
      _ -> nil
    end)
  end
  defp extract_result_text(%{content: text}) when is_binary(text), do: text
  defp extract_result_text(_), do: ""

  @doc """
  Canonical short identifier for a tool call. Used for history display
  and — critically — as the basis for stuck-loop repeat detection. Two
  calls that share the same summary are considered "the same call" for
  repeat-detection purposes, so every field that matters for
  distinguishing work (e.g. read_file offset/limit) must be included
  here.
  """
  def summarize_input(%{name: "shell", input: %{"command" => cmd}}) do
    String.slice(cmd, 0, 100)
  end

  def summarize_input(%{name: "write_file", input: %{"path" => path}}) do
    path
  end

  def summarize_input(%{name: "read_file", input: %{"path" => path} = input}) do
    parts = [path]
    parts = if input["offset"], do: parts ++ ["@#{input["offset"]}"], else: parts
    parts = if input["limit"], do: parts ++ ["+#{input["limit"]}"], else: parts
    Enum.join(parts)
  end

  def summarize_input(%{name: "edit_file", input: %{"path" => path}}), do: path
  def summarize_input(%{name: "list_directory", input: %{"path" => path}}), do: path
  def summarize_input(%{name: "glob", input: %{"pattern" => p}}), do: p
  def summarize_input(%{name: "grep", input: %{"pattern" => p}}), do: p
  def summarize_input(%{name: "web_search", input: %{"query" => q}}), do: String.slice(q, 0, 100)
  def summarize_input(%{name: "web_fetch", input: %{"url" => u}}), do: u
  def summarize_input(%{name: "screenshot", input: _}), do: "display"
  def summarize_input(%{name: "browse", input: %{"url" => u}}), do: u
  def summarize_input(%{name: "sub_agent", input: %{"goal" => g}}), do: String.slice(g, 0, 100)
  def summarize_input(%{name: "parallel_sub_agents", input: %{"agents" => a}}), do: "#{length(a)} agents"
  def summarize_input(%{name: "ask_user", input: %{"question" => q}}), do: String.slice(q, 0, 100)
  def summarize_input(%{name: "update_progress", input: _}), do: "progress"

  def summarize_input(%{name: name, input: input}) do
    "#{name}: #{inspect(input) |> String.slice(0, 100)}"
  end

  # Save state periodically (only for top-level runs, not sub-agents)
  defp maybe_save(%{depth: 0, run_id: run_id, step: step} = state) when not is_nil(run_id) do
    if Golem.State.should_save?(step) do
      # Include latest progress from persistent_term
      progress = :persistent_term.get(:golem_progress, [])
      Golem.State.save(run_id, Map.put(state, :progress, progress))
    end
  end
  defp maybe_save(_state), do: :ok

  # --- Phase Cost Tracking ---

  defp track_phase_costs(executed, costs, state) do
    # Check if update_progress was called with newly completed items
    progress_call = Enum.find(executed, fn {tc, _} -> tc.name == "update_progress" end)

    case progress_call do
      {tc, _} ->
        # Bump the call-step counter so the silence nudge knows the
        # agent did *something* on the checklist this turn, even if no
        # item advanced to completed. Gated to depth 0 — sub-agent
        # update_progress calls don't touch the parent's checklist
        # (tool_handler.ex:386), so they shouldn't reset the parent's
        # silence counter either.
        if state.depth == 0 do
          :persistent_term.put(:golem_last_progress_call_step, state.step)
        end

        items = Map.get(tc.input, "items", [])
        completed = Enum.count(items, fn i ->
          Map.get(i, "status", "") in ["completed", "complete", "done"]
        end)

        prev = Map.get(state, :last_completed, 0)

        if completed > prev do
          # New items completed — record cost for them and mark the step
          # so drift detection can measure progress staleness cheaply.
          :persistent_term.put(:golem_last_progress_step, state.step)
          cost_now = format_cost(costs)
          new_phases = Enum.filter(items, fn i ->
            Map.get(i, "status", "") in ["completed", "complete", "done"]
          end) |> Enum.map(& &1["text"]) |> Enum.take(completed - prev)

          new_entries = Enum.map(new_phases, fn name -> {name, cost_now} end)
          phase_costs = Map.get(state, :phase_costs, []) ++ new_entries

          {phase_costs, completed}
        else
          {Map.get(state, :phase_costs, []), prev}
        end

      nil ->
        {Map.get(state, :phase_costs, []), Map.get(state, :last_completed, 0)}
    end
  end

  defp log_phase_costs(state) do
    phase_costs = Map.get(state, :phase_costs, [])
    if phase_costs != [] do
      output().show_phase_costs(phase_costs)
    end
  end

  # --- Stuck & think loop detection ---
  #
  # Pure classification lives in Golem.Runner.Triggers. This module
  # owns the side effects: logging, model escalation, and turning the
  # classification into a warning message appended to the conversation.

  defp maybe_inject_stuck_warning(messages, executed, state) do
    step = state.step + 1
    current_escalation = Map.get(state, :escalated_until, 0)

    case Golem.Runner.Triggers.classify_stuck(state.history, executed) do
      {:edit_loop, stuck_files} ->
        Logger.warning("Stuck detection (edits): #{Enum.join(stuck_files, ", ")}")
        Golem.Events.emit(:stuck, %{step: step, category: "edit_loop", detail: stuck_files})

        msg =
          "[System] WARNING: You appear to be stuck in an edit loop on: " <>
            Enum.join(stuck_files, ", ") <>
            ". STOP editing and do one of these instead:\n1. Use `think` to step back and analyze WHY your edits keep failing\n2. Read the FULL file to understand the actual current state\n3. Try a completely different approach (e.g. rewrite the whole file instead of patching)\n4. Move on to a different task and come back to this later\n\nDo NOT make another edit to the same file without first explaining your new approach via `think`.\n\n[System] Escalating to a stronger model for the next #{@escalation_steps} steps."

        {messages ++ [%{role: "user", content: msg}], step + @escalation_steps}

      {:shell_loop, shell_repeats} ->
        Logger.warning("Stuck detection (shell): #{Enum.join(shell_repeats, ", ")}")
        Golem.Events.emit(:stuck, %{step: step, category: "shell_loop", detail: shell_repeats})

        msg =
          "[System] WARNING: You are repeating the same shell command(s): " <>
            Enum.join(shell_repeats, ", ") <>
            ". If it failed before, it will fail again. STOP and:\n1. Read the error output carefully\n2. Use `think` to analyze what's going wrong\n3. Try a fundamentally different approach\n\n[System] Escalating to a stronger model for the next #{@escalation_steps} steps."

        {messages ++ [%{role: "user", content: msg}], step + @escalation_steps}

      {:repeat_loop, count} ->
        Logger.warning("Stuck detection (repeat): #{count} repeated tool calls")
        Golem.Events.emit(:stuck, %{step: step, category: "repeat_loop", count: count})

        # Weak signal: deliver the warning but do NOT escalate. Previously
        # every repeat_loop hit bumped the model to Opus for 5 steps, and
        # because the detector fired constantly on normal iteration
        # (several reads of the same file, repeated shell sanity checks)
        # the executor stayed on Opus for the entire run. Edit and shell
        # loops are stronger signals and still escalate below.
        msg =
          "[System] WARNING: You are repeating identical tool calls without making progress. This is wasting steps. STOP and use `think` to analyze why you're stuck, then try a different approach."

        {messages ++ [%{role: "user", content: msg}], current_escalation}

      :ok ->
        {messages, current_escalation}
    end
  end

  # --- Think Loop Detection ---

  defp maybe_inject_think_warning(messages, executed, state) do
    tool_names = Enum.map(executed, fn {tc, _} -> tc.name end)
    prev_thinks = Map.get(state, :consecutive_thinks, 0)
    escalated_until = Map.get(state, :escalated_until, 0)

    case Golem.Runner.Triggers.classify_think_loop(tool_names, prev_thinks) do
      {:think_loop, consecutive} ->
        Logger.warning("Think loop detected: #{consecutive} consecutive think-only turns")
        step = state.step + 1
        Golem.Events.emit(:think_loop, %{step: step, consecutive: consecutive})

        msg =
          "[System] WARNING: You have called `think` #{consecutive} times in a row without taking any other action. Stop thinking and ACT. Use a tool that changes state — `shell`, `write_file`, `edit_file`, `sub_agent` — or call `done` if you're finished. Do NOT call `think` again without an accompanying action tool.\n\n[System] Escalating to a stronger model for the next #{@escalation_steps} steps."

        {messages ++ [%{role: "user", content: msg}], consecutive, step + @escalation_steps}

      {:ok, consecutive} ->
        {messages, consecutive, escalated_until}
    end
  end

  # --- Drift Detection ---

  # Every @drift_check_interval steps, compare recent activity against the plan.
  # Uses a cheap LLM call to detect if the agent has wandered off-plan.
  @drift_check_interval 15

  @max_consecutive_drifts 2

  # --- Per-turn system-reminder ---

  # Build a fresh <system-reminder> user message with current runtime state
  # and append it to the outgoing messages. Never appended to state.messages
  # — rebuilt from state + persistent_term each turn.
  #
  # Skipped early in the run (< 3 steps) when there's no useful state yet,
  # and for sub-agents (depth > 0) which have narrower context already.
  # Pure rendering lives in Golem.Runner.Reminder.
  defp maybe_append_system_reminder(messages, %{depth: 0, step: step} = state) when step >= 3 do
    reminder =
      Golem.Runner.Reminder.build(
        step: state.step,
        max_steps: state.max_steps,
        cost: Map.get(state.costs, :total_dollars, 0.0),
        budget: Application.get_env(:golem, :max_cost, 10.0),
        progress: :persistent_term.get(:golem_progress, []),
        history: state.history,
        recent_n: 5
      )

    messages ++ [%{role: "user", content: reminder}]
  end

  defp maybe_append_system_reminder(messages, _state), do: messages

  defp maybe_inject_drift_warning(%{step: step, plan: plan, depth: depth} = state)
       when depth == 0 and plan != nil and step > 0 do
    # Cheap heuristic: progress staleness — runs every step with no LLM cost.
    state_with_staleness = maybe_inject_staleness_nudge(state)

    # LLM drift check gated on interval AND at least one cheap signal tripping.
    if rem(step, @drift_check_interval) == 0 do
      run_llm_drift_check(state_with_staleness)
    else
      {state_with_staleness.messages, Map.get(state, :consecutive_drifts, 0)}
    end
  end

  defp maybe_inject_drift_warning(state), do: {state.messages, Map.get(state, :consecutive_drifts, 0)}

  # Progress silence nudge — fires when the agent hasn't called
  # `update_progress` at all in a few turns while non-completed items
  # remain. Distinct from the staleness nudge below: that one fires on
  # "no completed items in N steps", which only catches an agent that
  # *finished* nothing for a long time. This one catches the more
  # common case — an agent doing real work but skipping the bookkeeping
  # tool turn after turn, leaving the operator's TUI checklist out of
  # sync with reality.
  #
  # Gated to depth 0: sub-agents don't drive the parent's TUI checklist
  # (tool_handler.ex:386), so silence at depth > 0 isn't a problem.
  defp maybe_inject_progress_silence_nudge(messages, %{depth: 0}, step) do
    progress = :persistent_term.get(:golem_progress, [])
    has_pending? = Enum.any?(progress, &(&1.status not in [:completed, :done]))
    last_call = :persistent_term.get(:golem_last_progress_call_step, 0)
    last_nudge = :persistent_term.get(:golem_last_silence_nudge_step, 0)

    case Golem.Runner.Triggers.check_progress_call_silence(step, last_call, last_nudge, has_pending?) do
      {:nudge, gap} ->
        :persistent_term.put(:golem_last_silence_nudge_step, step)
        Logger.warning("Progress silence: no update_progress call in #{gap} turns")
        Golem.Events.emit(:progress_silence_nudge, %{step: step, gap: gap})

        msg = """
        [System] You have not called `update_progress` in #{gap} turns. The operator's checklist still shows your status from before that work — it's wrong now.

        On your NEXT turn, call `update_progress` with the FULL item list. Mark items you've finished as `completed`, the one you're currently working on as `in_progress`, the rest as `pending`. Then continue the work in the same turn or the next one — `update_progress` is silent and cheap, it won't slow you down.

        The TUI checklist is a contract with the operator. Leaving it stale while you do real work makes them think you're stuck.
        """

        messages ++ [%{role: "user", content: msg}]

      :ok ->
        messages
    end
  end

  defp maybe_inject_progress_silence_nudge(messages, _state, _step), do: messages

  # Progress staleness nudge — heuristic detection lives in
  # Golem.Runner.Triggers; this wrapper handles :persistent_term side
  # effects and message injection.
  defp maybe_inject_staleness_nudge(%{step: step} = state) do
    last_progress = :persistent_term.get(:golem_last_progress_step, 0)
    last_nudge = :persistent_term.get(:golem_last_staleness_nudge, 0)

    case Golem.Runner.Triggers.check_staleness(step, last_progress, last_nudge) do
      {:nudge, gap} ->
        :persistent_term.put(:golem_last_staleness_nudge, step)
        Logger.warning("Progress staleness: no completed items in #{gap} steps")
        Golem.Events.emit(:staleness_nudge, %{step: step, gap: gap})

        # Directive, not suggestion: the agent has been quietly ignoring
        # the soft "please update_progress" wording. The TUI checklist
        # is a user-facing contract — leaving it out of sync with reality
        # is a bug, not a style choice.
        msg = """
        [System] PROGRESS CHECKLIST IS STALE. You have not marked any item completed in #{gap} steps, and the checklist the operator sees in the TUI is out of sync with what you're actually doing.

        Before your next substantive tool call, you MUST either:

        1. Call `update_progress` to mark items you've finished AND mark the item you're currently working on as in_progress. Be honest — if you've skipped a step because it wasn't needed (e.g. environment already set up), mark it completed with a one-word note.
        2. If you're genuinely blocked on the current item, use `think(request_replan: true)` to get a revised plan.

        Do NOT continue the current line of work while the checklist is wrong. An out-of-sync checklist makes the operator think you're stuck on something you're not, and makes it impossible to tell whether the run is making progress.
        """

        %{state | messages: state.messages ++ [%{role: "user", content: msg}]}

      :ok ->
        state
    end
  end

  defp run_llm_drift_check(state) do
    signals =
      Golem.Runner.Triggers.drift_signals(
        step: state.step,
        history: state.history,
        last_progress_step: :persistent_term.get(:golem_last_progress_step, 0)
      )

    consecutive = Map.get(state, :consecutive_drifts, 0)

    if signals == [] do
      # No cheap signal tripped — don't spend the LLM call
      {state.messages, 0}
    else
      Golem.Events.emit(:drift_check, %{signals: Enum.map(signals, &Atom.to_string/1)})
      do_llm_drift_check(state, consecutive)
    end
  end

  defp do_llm_drift_check(%{step: step, plan: plan, history: history} = state, consecutive) do
    recent =
      history
      |> Enum.take(-15)
      |> Enum.map(fn {tool, input, _result} -> "- [#{tool}] #{input}" end)
      |> Enum.join("\n")

    case check_drift(plan, recent) do
      {:drifting, explanation} ->
        new_consecutive = consecutive + 1
        Logger.warning("Drift detected at step #{step} (#{new_consecutive} consecutive): #{String.slice(explanation, 0, 200)}")
        Golem.Events.emit(:drift, %{
          step: step,
          consecutive: new_consecutive,
          explanation: String.slice(explanation, 0, 500)
        })

        msg =
          if new_consecutive >= @max_consecutive_drifts do
            """
            [System] DRIFT WARNING (#{new_consecutive}x consecutive): You are persistently off-plan.

            #{explanation}

            You MUST call `think(request_replan: true)` NOW. Include what you've actually been doing \
            and why the current plan doesn't match. The planner will revise the plan to match reality. \
            Do NOT continue without replanning.
            """
          else
            """
            [System] DRIFT WARNING: You appear to be working on tasks not in the plan.

            #{explanation}

            Get back on track. Check your progress checklist and resume the next uncompleted item. \
            If the plan genuinely needs to change, use `think(request_replan: true)` instead of silently diverging.
            """
          end

        {state.messages ++ [%{role: "user", content: msg}], new_consecutive}

      :on_track ->
        {state.messages, 0}
    end
  end

  @drift_prompt """
  You are checking whether an autonomous agent is following its plan.

  Given the PLAN and the agent's RECENT ACTIONS, determine if the agent is on track or drifting.

  Drifting means: working on tasks not mentioned in the plan, adding unrequested features, \
  refactoring code that isn't part of the current phase, or doing research unrelated to the goal.

  NOT drifting: fixing errors that arose from plan steps, installing dependencies needed by the plan, \
  debugging test failures, or doing sub-steps implied by the plan even if not explicitly listed.

  Respond with EXACTLY one of:
  - ON_TRACK
  - DRIFTING: <one sentence explaining what they're doing that's off-plan>

  No other output.
  """

  defp check_drift(plan, recent_actions) do
    messages = [
      %{role: "user", content: "## Plan\n\n#{String.slice(plan, 0, 3000)}\n\n## Recent Actions\n\n#{recent_actions}"}
    ]

    model = Application.get_env(:golem, :executor_model)

    case Golem.Claude.call(messages, model: model, max_tokens: 200, system: @drift_prompt) do
      {:ok, %{text: text}} when is_binary(text) ->
        trimmed = String.trim(text)

        if String.starts_with?(trimmed, "DRIFTING:") do
          {:drifting, String.trim_leading(trimmed, "DRIFTING:") |> String.trim()}
        else
          :on_track
        end

      _ ->
        :on_track
    end
  end

  # --- File Size Warnings ---
  #
  # Detection lives in Golem.Runner.Triggers. This wrapper filters for
  # successful writes (we only warn about files that actually landed)
  # and handles logging + message injection.

  defp maybe_inject_file_size_warning(messages, executed) do
    successful_writes =
      Enum.filter(executed, fn {_, result} ->
        match?({:text, "File written" <> _}, result)
      end)

    oversized = Golem.Runner.Triggers.oversized_writes(successful_writes)
    threshold = Golem.Runner.Triggers.thresholds().file_size

    case oversized do
      [] ->
        messages

      entries ->
        files = Enum.map_join(entries, ", ", fn {path, lines} -> "#{path} (#{lines} lines)" end)
        Logger.warning("Large file warning: #{files}")
        Golem.Events.emit(:file_size_warning, %{
          files: Enum.map(entries, fn {p, l} -> %{path: p, lines: l} end),
          threshold: threshold
        })

        msg =
          "[System] WARNING: You wrote large file(s): #{files}. Files over #{threshold} lines are harder to edit reliably — `edit_file` failures increase with file size. Consider splitting into smaller modules (e.g., one file per struct/component/handler). This is not optional cleanup — it directly prevents edit failures in later steps."

        messages ++ [%{role: "user", content: msg}]
    end
  end

  # --- Self-Review ---

  @review_threshold 30  # lines

  defp maybe_inject_review(messages, executed) do
    large_writes =
      executed
      |> Enum.filter(fn {tc, result} ->
        tc.name == "write_file" and match?({:text, "File written" <> _}, result) and
          (tc.input["content"] || "") |> String.split("\n") |> length() > @review_threshold
      end)
      |> Enum.map(fn {tc, _} -> tc.input["path"] end)

    if large_writes != [] do
      files = Enum.join(large_writes, ", ")
      messages ++ [
        %{role: "user", content: "[System] You just wrote large file(s): #{files}. Use the `think` tool to silently review the code for obvious bugs, missing imports, and incomplete functions. Do NOT print the review — just think through it internally and fix any issues you find."}
      ]
    else
      messages
    end
  end

  # --- Error-Triggered Search Nudge ---

  # When build/compile errors mention unknown symbols, modules, or types,
  # nudge the agent to search for documentation instead of guessing fixes.
  # This catches the case where the agent has stale training data for a
  # framework (e.g. Tauri 1 vs 2) and keeps retrying wrong APIs.

  @build_error_patterns [
    ~r/(?:cannot find|not found|unknown|undefined|unresolved)\s+(?:function|method|type|module|struct|crate|package|symbol|trait|macro)/i,
    ~r/(?:no such|does not exist|not a member|has no)\s+(?:function|method|field|variant|module|attribute)/i,
    ~r/error\[E\d+\]/,                     # Rust compiler errors
    ~r/(?:ModuleNotFoundError|ImportError)/, # Python
    ~r/Cannot find module/,                  # Node/TypeScript
    ~r/undefined function .+ is not available/,  # Elixir
    ~r/the trait .+ is not implemented/i,    # Rust trait errors
    ~r/expected one of .+ found/i,           # API signature mismatches
  ]

  defp maybe_inject_search_nudge(messages, executed, state) do
    # Only check shell results that look like build/compile errors
    build_errors =
      executed
      |> Enum.filter(fn {tc, result} ->
        tc.name == "shell" and
          match?({:text, "[exit code" <> _}, result)
      end)
      |> Enum.flat_map(fn {tc, {:text, text}} ->
        cmd = tc.input["command"] || ""
        is_build = String.contains?(cmd, ["cargo", "npm", "mix", "python", "pip", "go ", "rustc", "gcc", "make", "cmake", "tsc", "node", "bun", "deno", "gradle", "mvn"])

        if is_build and Enum.any?(@build_error_patterns, &Regex.match?(&1, text)) do
          # Extract a useful snippet of the error
          error_lines = text
                        |> String.split("\n")
                        |> Enum.filter(&String.match?(&1, ~r/error|not found|unknown|undefined|cannot find/i))
                        |> Enum.take(3)
                        |> Enum.join("\n")
          [error_lines]
        else
          []
        end
      end)

    # Check if we've seen build errors recently (repeat = agent is guessing)
    recent_build_errors =
      state.errors
      |> Enum.count(&String.contains?(&1, ["not found", "unknown", "undefined", "cannot find", "unresolved"]))

    if build_errors != [] and recent_build_errors >= 1 do
      error_snippet = Enum.join(build_errors, "\n")
      Logger.warning("Search nudge: build errors with unknown symbols (#{recent_build_errors} prior similar errors)")
      messages ++ [
        %{role: "user", content: "[System] You have repeated build errors involving unknown functions, types, or modules:\n\n#{String.slice(error_snippet, 0, 300)}\n\nThis strongly suggests your training data for this library/framework is OUTDATED. Do NOT guess at the fix. Instead:\n1. Use `web_search` to find the CURRENT documentation for the library and version you're using\n2. Search for the specific error message\n3. Check if there was a major version upgrade with breaking API changes\n\nDo NOT edit the code again until you have searched for the correct API."}
      ]
    else
      messages
    end
  end

  # --- Error Memory ---

  defp extract_errors(executed) do
    executed
    |> Enum.flat_map(fn {tc, result} ->
      case result do
        {:text, text} when is_binary(text) ->
          cond do
            String.starts_with?(text, "[error]") ->
              ["#{tc.name}: #{String.slice(text, 0, 150)}"]
            String.starts_with?(text, "[exit code") ->
              # Extract the meaningful error from compiler/runtime output
              error_line = text |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "error")) || String.slice(text, 0, 100)
              ["#{tc.name}: #{String.slice(error_line, 0, 150)}"]
            true -> []
          end
        _ -> []
      end
    end)
  end

  # --- Cost Tracking ---

  # Pricing per million tokens (as of 2025)
  # Pricing per million tokens in USD. Defaults match Anthropic's
  # public pricing as of 2026-04. Users can override any model in
  # `.golem/config.yml` under the `pricing:` block — useful if
  # Anthropic bumps prices between Golem releases, or to model other
  # providers once multi-provider lands.
  #
  # Example override:
  #
  #     pricing:
  #       claude-opus-4-7:
  #         input: 15.0
  #         output: 75.0
  #         cache_read: 1.5
  #         cache_create: 18.75
  @default_sonnet_pricing %{input: 3.0, output: 15.0, cache_read: 0.3, cache_create: 3.75}
  @default_opus_pricing %{input: 15.0, output: 75.0, cache_read: 1.5, cache_create: 18.75}

  defp pricing_for(model) when is_binary(model) do
    overrides = Golem.Config.raw_yaml() |> get_in(["pricing", model]) || %{}
    base = if String.contains?(model, "opus"), do: @default_opus_pricing, else: @default_sonnet_pricing

    # Accept both string and atom keys; users will almost always write
    # strings in YAML. Merge over the matching base so partial
    # overrides (e.g. just `input:`) work.
    Enum.reduce(base, %{}, fn {key, default}, acc ->
      override = overrides[to_string(key)] || overrides[key]
      Map.put(acc, key, if(is_number(override), do: override * 1.0, else: default))
    end)
  end

  @doc """
  Compute the dollar cost of a single Claude.call usage map for the
  given model. Pure helper — used by the runner for per-turn cost
  accumulation and by the Jira evaluator to fold pre-flight spend
  into the run total.
  """
  def usage_cost(usage, model) when is_binary(model) do
    p = pricing_for(model)
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)
    cache_read = Map.get(usage, :cache_read, 0)
    cache_create = Map.get(usage, :cache_create, 0)

    input / 1_000_000 * p.input +
      output / 1_000_000 * p.output +
      cache_read / 1_000_000 * p.cache_read +
      cache_create / 1_000_000 * p.cache_create
  end

  defp accumulate_costs(costs, usage, model) do
    step_cost = usage_cost(usage, model)
    Map.update(costs, :total_dollars, step_cost, &(&1 + step_cost))
  end

  defp format_cost(%{total_dollars: dollars}) do
    :erlang.float_to_binary(dollars, decimals: 4)
  end

  defp format_cost(_costs), do: "0.0000"

  defp depth_prefix(0), do: ""
  defp depth_prefix(depth), do: String.duplicate("│ ", depth)
end
