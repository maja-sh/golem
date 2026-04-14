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

    Logger.info("#{prefix}========== RUN STARTED (#{run_id}) ==========")
    Logger.info("#{prefix}Goal: #{goal}")
    Logger.info("#{prefix}Depth: #{depth}, Max steps: #{max_steps}")

    result = do_run(goal, opts, max_steps, depth, prefix, run_id)

    if depth == 0 do
      case result do
        {:ok, %{success: success} = s} -> output().run_complete(success, s.summary)
        {:error, :max_steps_reached} -> output().run_paused(run_id)
        {:error, reason} -> output().run_error(reason)
      end

      output().stop_display()
    end

    # Always log to file
    case result do
      {:ok, %{success: true} = s} -> Logger.info("#{prefix}RUN SUCCEEDED: #{s.summary}")
      {:ok, %{success: false} = s} -> Logger.info("#{prefix}RUN FAILED: #{s.summary}")
      {:error, :max_steps_reached} -> Logger.warning("#{prefix}RUN PAUSED — resume: #{run_id}")
      {:error, reason} -> Logger.error("#{prefix}RUN ERROR: #{inspect(reason)}")
    end

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

        Logger.info("#{prefix}========== RESUMING RUN #{run_id} ==========")
        Logger.info("#{prefix}Continuing from step #{saved.step}, new max: #{new_max}")

        if saved.depth == 0 do
          output().init_display(run_id, saved.goal)
          output().planning("Resuming from step #{saved.step}...")
          # Restore progress checklist
          progress = Map.get(saved, :progress, [])
          if progress != [], do: output().set_progress(progress)
        end

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

        # If no progress items, tell the agent to set them up
        state =
          if Map.get(saved, :progress, []) == [] and state.messages != [] do
            resume_msg = %{role: "user", content: "[System] Run resumed. Use `update_progress` to set your current progress checklist before continuing."}
            %{state | messages: state.messages ++ [resume_msg]}
          else
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

        # Always log to file
        case result do
          {:ok, %{success: true} = s} -> Logger.info("#{prefix}RUN SUCCEEDED: #{s.summary}")
          {:ok, %{success: false} = s} -> Logger.info("#{prefix}RUN FAILED: #{s.summary}")
          {:error, :max_steps_reached} -> Logger.warning("#{prefix}RUN PAUSED — resume: #{run_id}")
          {:error, reason} -> Logger.error("#{prefix}RUN ERROR: #{inspect(reason)}")
        end

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
          create_plan(goal)

        plan ->
          {:ok, plan}
      end

    case plan_result do
      {:ok, plan} ->
        if depth == 0, do: output().plan_created(plan)
        Logger.info("#{prefix}Plan created (logged to file)")

        state = %{
          goal: goal,
          plan: plan,
          messages: [],
          step: 0,
          max_steps: max_steps,
          depth: depth,
          prefix: prefix,
          history: [],
          costs: %{total_dollars: 0.0},
          errors: [],
          agents_md: opts[:agents_md],
          phase_costs: [],
          last_completed: 0,
          run_id: run_id
        }

        system = Golem.Prompt.executor_system([])
        initial = Golem.Prompt.initial_message(goal, plan)
        state = %{state | messages: [%{role: "user", content: initial}]}

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
  def run_sub_agent(goal, context, parent_depth, parent_state \\ nil) do
    depth = parent_depth + 1
    prefix = depth_prefix(depth)
    Logger.info("#{prefix}---------- SUB-AGENT SPAWNED ----------")
    Logger.info("#{prefix}Goal: #{String.slice(goal, 0, 500)}")
    if parent_depth == 0, do: output().sub_agent_start(goal)

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
      max_steps: @sub_agent_max_steps,
      depth: depth,
      prefix: prefix,
      history: [],
      costs: %{total_dollars: 0.0},
      errors: errors,
      phase_costs: [],
      last_completed: 0
    }

    result = loop(state, system)
    Logger.info("#{prefix}---------- SUB-AGENT FINISHED ----------")

    # Report sub-agent completion to TUI
    if parent_depth == 0 do
      {success, steps} = case result do
        {:ok, %{success: s}} -> {s, state.step}
        _ -> {false, state.step}
      end
      output().sub_agent_result(goal, steps, success)
    end

    # Extract files created/modified by the sub-agent for parent awareness
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

  defp create_plan(goal) do
    model = Application.get_env(:golem, :planner_model)
    max_tokens = Application.get_env(:golem, :planner_max_tokens, 4096)
    thinking_budget = Application.get_env(:golem, :thinking_budget, 10_000)

    messages = [
      %{role: "user", content: "Create a plan for this goal:\n\n#{goal}"}
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
    # Check for stop signal (from DaemonRunner.stop_run)
    else
      if check_stop() do
        Logger.info("Stop requested — saving state")
        if run_id = Map.get(state, :run_id), do: Golem.State.save(run_id, state)
        {:error, :stopped}
      else
        do_loop(state)
      end
    end
  end

  defp check_stop do
    receive do
      :stop_requested -> true
    after
      0 -> false
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
    Logger.info("#{p}--- Step #{step}/#{state.max_steps} | #{cost_str} ---")
    if state.depth == 0, do: output().step_header(step, state.max_steps, cost_str)

    # Rebuild system prompt with current error memory and AGENTS.md
    agents_md = Map.get(state, :agents_md)
    system = Golem.Prompt.executor_system(errors, agents_md)

    # Escalate to Opus when stuck, drop back after a few steps
    model =
      if Map.get(state, :escalated_until, 0) > step do
        Logger.info("#{p}  [escalated to Opus]")
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

        if response.text do
          Logger.info("#{p}  Agent: #{response.text}")
          if state.depth == 0, do: output().agent_text(response.text)
        end

        if is_nil(response.text) and state.depth == 0 do
          count = length(tool_calls)
          if count > 1 do
            output().agent_text("Running #{count} actions (#{Golem.TUI.format_elapsed(llm_elapsed)})")
          end
        end

        Logger.info("#{p}  (#{Golem.TUI.format_elapsed(llm_elapsed)} · #{length(tool_calls)} tools · ↓ #{Golem.TUI.format_tokens(output_tokens)})")

        costs = accumulate_costs(costs, response.usage, model)
        if state.depth == 0, do: output().update_tokens(output_tokens)

        # Execute all tool calls, stopping early on done/think_replan
        case execute_tool_calls(tool_calls, state.depth, state) do
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
                Logger.info("#{p}  Total cost: $#{format_cost(costs)}")
                log_phase_costs(state)
                maybe_save(state)
                {:ok, summary}

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
        Logger.info("#{p}  Agent (no tool, #{no_tool_count}x): #{text}")
        costs = accumulate_costs(costs, response.usage, model)
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

  # Run a batch of read-only tools concurrently using Task.async.
  defp execute_concurrent_batch(batch, depth, show, state) do
    batch_start = System.monotonic_time(:millisecond)

    # Show status while batch runs (not individual headers)
    if show and length(batch) > 1 do
      names = batch |> Enum.map(& &1.name) |> Enum.frequencies()
      label = Enum.map_join(names, " + ", fn {n, c} -> if c > 1, do: "#{c}x #{n}", else: n end)
      output().tool_call("batch", label)
    else if show do
      [tc] = batch
      silent = tc.name in @silent_tools
      if not silent, do: output().tool_call(tc.name, summarize_input(tc))
    end end

    # Execute all in parallel
    tasks =
      Enum.map(batch, fn tc ->
        Task.async(fn ->
          start = System.monotonic_time(:millisecond)
          result = Golem.ToolHandler.execute(tc, depth) |> Golem.ToolHandler.truncate_result()
          elapsed = System.monotonic_time(:millisecond) - start
          {tc, result, elapsed}
        end)
      end)

    results = Task.await_many(tasks, :infinity)
    batch_elapsed = System.monotonic_time(:millisecond) - batch_start

    # Collapsed display for multi-tool batches
    if show and length(results) > 1 do
      batch_summary =
        Enum.map(results, fn {tc, result, _elapsed} ->
          detail = summarize_input(tc)
          is_error = case result do
            {:continue, text} -> String.starts_with?(text, "[error]") or String.starts_with?(text, "[exit code")
            _ -> false
          end
          {tc.name, detail, is_error}
        end)
      output().tool_batch_result(batch_summary, batch_elapsed)
    end

    # Build return entries + handle single-tool display and sub-agent status
    Enum.map(results, fn {tc, result, elapsed} ->
      detail = summarize_input(tc)
      silent = tc.name in @silent_tools

      case result do
        {:continue, text} ->
          is_error = String.starts_with?(text, "[error]") or String.starts_with?(text, "[exit code")

          # Single-tool batch: show individual result (multi-tool already collapsed above)
          if show and not silent and length(results) == 1 do
            if is_error,
              do: output().tool_error(tc.name, detail, text),
              else: output().tool_result(tc.name, detail, text, elapsed, nil)
          end

          # Sub-agent: show condensed status line
          if not show and not silent and state do
            emit_sub_agent_status(state, tc.name, detail)
          end

          {tc, {:text, text}}

        {:continue_with_image, %{text: text, base64: base64}} ->
          if show and not silent and length(results) == 1 do
            output().tool_result(tc.name, detail, text, elapsed, nil)
          end
          if not show and not silent and state do
            emit_sub_agent_status(state, tc.name, detail)
          end
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

    # Sub-agent: show condensed status in the spinner line
    if not show and not silent and state do
      emit_sub_agent_status(state, tc.name, detail)
    end

    case Golem.ToolHandler.execute(tc, depth) |> Golem.ToolHandler.truncate_result() do
      {:done, summary} ->
        elapsed = System.monotonic_time(:millisecond) - start
        if show, do: output().tool_result(tc.name, detail, summary.summary, elapsed, nil)
        {:done, summary, {tc, {:text, "Goal completed."}}}

      {:think_replan, reasoning} ->
        elapsed = System.monotonic_time(:millisecond) - start
        if show, do: output().tool_result(tc.name, detail, "Re-planning...", elapsed, nil)
        {:think_replan, reasoning, {tc, {:text, "Re-planning requested."}}}

      {:continue, result} ->
        elapsed = System.monotonic_time(:millisecond) - start
        is_error = String.starts_with?(result, "[error]") or String.starts_with?(result, "[exit code")

        if show and not silent do
          if is_error,
            do: output().tool_error(tc.name, detail, result),
            else: output().tool_result(tc.name, detail, result, elapsed, nil)
        end

        {:continue, {tc, {:text, result}}}

      {:continue_with_image, %{text: text, base64: base64}} ->
        elapsed = System.monotonic_time(:millisecond) - start
        if show and not silent, do: output().tool_result(tc.name, detail, text, elapsed, nil)
        {:continue, {tc, {:image, text, base64}}}
    end
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
            {:text, text} -> text
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
      Logger.info("#{state.prefix}  Re-planning with Opus (#{replan_count}/#{@max_replans})...")
      if state.depth == 0, do: output().planning("Re-planning with Opus (#{replan_count}/#{@max_replans})...")

      # Take last 20 history entries for context
      recent = Enum.take(state.history, -20)

      # State already has the tool exchange messages appended from execute_tool_calls
      case replan(state.goal, state.plan, reasoning, recent) do
        {:ok, new_plan} ->
          Logger.info("#{state.prefix}  Revised plan:\n#{new_plan}")

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

    if not summary.success or state.depth > 0 or rejections >= @max_done_rejections do
      {:accept, state}
    else
      Logger.info("#{state.prefix}  Verifying before accepting done (attempt #{rejections + 1})...")
      if state.depth == 0, do: output().planning("Running verification checks...")

      case Golem.Verify.run_checks() do
        {:ok, nil} ->
          # No project detected — nothing to verify
          {:accept, state}

        {:ok, project_path} ->
          # Compile + tests passed. Now run a fresh sub-agent for deeper review.
          Logger.info("#{state.prefix}  Programmatic checks passed, running verification agent...")
          if state.depth == 0, do: output().planning("Running verification agent...")

          case Golem.Verify.run_agent(project_path) do
            :ok ->
              Logger.info("#{state.prefix}  Verification passed")
              {:accept, state}

            {:error, issues} ->
              reject_done(state, "Verification agent found issues:\n\n#{issues}")
          end

        {:error, issues} ->
          reject_done(state, issues)
      end
    end
  end

  defp reject_done(state, issues) do
    rejections = Map.get(state, :done_rejections, 0) + 1

    Logger.warning(
      "#{state.prefix}  Done REJECTED (#{rejections}/#{@max_done_rejections}): " <>
        String.slice(issues, 0, 300)
    )

    if state.depth == 0 do
      output().planning("Verification failed — sending agent back to fix (#{rejections}/#{@max_done_rejections})")
    end

    messages =
      state.messages ++
        [
          %{
            role: "user",
            content: """
            [System] Your `done` call was REJECTED because verification failed (attempt #{rejections}/#{@max_done_rejections}):

            #{issues}

            Fix ALL of these issues, then call `done` again. Do not skip any.
            """
          }
        ]

    {:reject, state |> Map.put(:messages, messages) |> Map.put(:done_rejections, rejections)}
  end

  # --- Microcompaction ---

  # Selectively clear bulky tool results from older messages.
  # Keeps the last @micro_keep_recent messages untouched. For older messages,
  # replaces large tool_result content with "[cleared]" — the tool name and
  # structure are preserved so the model still knows what happened.
  @micro_keep_recent 6
  @micro_clearable_tools ~w(shell read_file grep glob web_search web_fetch list_directory browse)
  @micro_min_size 200

  defp microcompact(messages) when length(messages) <= @micro_keep_recent, do: messages

  defp microcompact(messages) do
    split_at = max(0, length(messages) - @micro_keep_recent)
    {old, recent} = Enum.split(messages, split_at)

    # Build a map of tool_use_id → tool_name from assistant messages
    tool_names = build_tool_name_index(old)

    Enum.map(old, &microcompact_message(&1, tool_names)) ++ recent
  end

  defp build_tool_name_index(messages) do
    messages
    |> Enum.filter(&(&1.role == "assistant"))
    |> Enum.flat_map(fn msg ->
      case msg.content do
        blocks when is_list(blocks) ->
          Enum.flat_map(blocks, fn
            %{type: "tool_use", id: id, name: name} -> [{id, name}]
            %{"type" => "tool_use", "id" => id, "name" => name} -> [{id, name}]
            _ -> []
          end)
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp microcompact_message(%{role: "user", content: content} = msg, tool_names) when is_list(content) do
    %{msg | content: Enum.map(content, &maybe_clear_tool_result(&1, tool_names))}
  end

  defp microcompact_message(msg, _tool_names), do: msg

  defp maybe_clear_tool_result(%{type: "tool_result", content: content} = block, tool_names) when is_binary(content) do
    id = Map.get(block, :tool_use_id) || Map.get(block, "tool_use_id")
    tool_name = Map.get(tool_names, id)

    if byte_size(content) > @micro_min_size and tool_name in @micro_clearable_tools do
      %{block | content: "[cleared]"}
    else
      block
    end
  end

  defp maybe_clear_tool_result(%{"type" => "tool_result", "content" => content} = block, tool_names) when is_binary(content) do
    id = Map.get(block, "tool_use_id")
    tool_name = Map.get(tool_names, id)

    if byte_size(content) > @micro_min_size and tool_name in @micro_clearable_tools do
      Map.put(block, "content", "[cleared]")
    else
      block
    end
  end

  defp maybe_clear_tool_result(block, _tool_names), do: block

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
        Logger.info("  Snip compact: removed #{middle_removed} middle messages (~#{token_est - estimate_tokens(head ++ tail)} tokens freed)")

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
      if token_est > @compact_token_threshold do
        Logger.info("  Compacting: ~#{token_est} estimated tokens exceeds #{@compact_token_threshold} threshold")
      else
        Logger.info("  Compacting: #{msg_count} messages exceeds #{@compact_threshold} threshold")
      end

      do_trim_messages(messages)
    end
  end

  defp do_trim_messages(messages) do
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

  # Rough token estimation: ~4 bytes per token for English text.
  # Conservative (overestimates) to trigger compaction early rather than late.
  defp estimate_tokens(messages) do
    messages
    |> Enum.map(&estimate_message_tokens/1)
    |> Enum.sum()
    |> div(1)  # already in tokens
  end

  defp estimate_message_tokens(%{content: content}) when is_binary(content) do
    div(byte_size(content), 4)
  end

  defp estimate_message_tokens(%{content: blocks}) when is_list(blocks) do
    Enum.reduce(blocks, 0, fn
      %{type: "text", text: text}, acc -> acc + div(byte_size(text), 4)
      %{"type" => "text", "text" => text}, acc -> acc + div(byte_size(text), 4)
      %{type: "tool_result", content: content}, acc when is_binary(content) -> acc + div(byte_size(content), 4)
      %{"type" => "tool_result", "content" => content}, acc when is_binary(content) -> acc + div(byte_size(content), 4)
      %{type: "tool_use", input: input}, acc -> acc + div(byte_size(inspect(input)), 4)
      %{"type" => "tool_use", "input" => input}, acc -> acc + div(byte_size(inspect(input)), 4)
      %{type: "image"}, acc -> acc + 2000  # images are ~2000 tokens
      _, acc -> acc + 50  # small overhead for other block types
    end)
  end

  defp estimate_message_tokens(_), do: 50

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

  defp summarize_input(%{name: "shell", input: %{"command" => cmd}}) do
    String.slice(cmd, 0, 100)
  end

  defp summarize_input(%{name: "write_file", input: %{"path" => path}}) do
    path
  end

  defp summarize_input(%{name: "read_file", input: %{"path" => path}}), do: path
  defp summarize_input(%{name: "edit_file", input: %{"path" => path}}), do: path
  defp summarize_input(%{name: "list_directory", input: %{"path" => path}}), do: path
  defp summarize_input(%{name: "glob", input: %{"pattern" => p}}), do: p
  defp summarize_input(%{name: "grep", input: %{"pattern" => p}}), do: p
  defp summarize_input(%{name: "web_search", input: %{"query" => q}}), do: String.slice(q, 0, 100)
  defp summarize_input(%{name: "web_fetch", input: %{"url" => u}}), do: u
  defp summarize_input(%{name: "screenshot", input: _}), do: "display"
  defp summarize_input(%{name: "browse", input: %{"url" => u}}), do: u
  defp summarize_input(%{name: "sub_agent", input: %{"goal" => g}}), do: String.slice(g, 0, 100)
  defp summarize_input(%{name: "parallel_sub_agents", input: %{"agents" => a}}), do: "#{length(a)} agents"
  defp summarize_input(%{name: "ask_user", input: %{"question" => q}}), do: String.slice(q, 0, 100)
  defp summarize_input(%{name: "update_progress", input: _}), do: "progress"

  defp summarize_input(%{name: name, input: input}) do
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
        items = Map.get(tc.input, "items", [])
        completed = Enum.count(items, fn i ->
          Map.get(i, "status", "") in ["completed", "complete", "done"]
        end)

        prev = Map.get(state, :last_completed, 0)

        if completed > prev do
          # New items completed — record cost for them
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
      Logger.info("Phase cost breakdown:")
      Enum.each(phase_costs, fn {name, cost} ->
        Logger.info("  #{name}: $#{cost}")
      end)

      output().show_phase_costs(phase_costs)
    end
  end

  # --- Stuck Detection ---

  @stuck_edit_threshold 4
  @stuck_shell_threshold 3
  @stuck_repeat_threshold 3

  defp maybe_inject_stuck_warning(messages, executed, state) do
    recent_history = Enum.take(state.history, -15)
    step = state.step + 1
    current_escalation = Map.get(state, :escalated_until, 0)

    # 1. File edit loops: same file edited 4+ times
    current_edits = executed
                    |> Enum.filter(fn {tc, _} -> tc.name in ["edit_file", "write_file"] end)
                    |> Enum.map(fn {tc, _} -> tc.input["path"] end)
                    |> Enum.reject(&is_nil/1)

    recent_edits = recent_history
                   |> Enum.filter(fn {tool, _, _} -> tool in ["edit_file", "write_file"] end)
                   |> Enum.map(fn {_, path, _} -> path end)

    stuck_files =
      (recent_edits ++ current_edits)
      |> Enum.frequencies()
      |> Enum.filter(fn {_, count} -> count >= @stuck_edit_threshold end)
      |> Enum.map(fn {file, count} -> "#{Path.basename(file)} (#{count} edits)" end)

    if stuck_files != [] do
      Logger.warning("Stuck detection (edits): #{Enum.join(stuck_files, ", ")}")
      {messages ++ [
        %{role: "user", content: "[System] WARNING: You appear to be stuck in an edit loop on: #{Enum.join(stuck_files, ", ")}. STOP editing and do one of these instead:\n1. Use `think` to step back and analyze WHY your edits keep failing\n2. Read the FULL file to understand the actual current state\n3. Try a completely different approach (e.g. rewrite the whole file instead of patching)\n4. Move on to a different task and come back to this later\n\nDo NOT make another edit to the same file without first explaining your new approach via `think`.\n\n[System] Escalating to a stronger model for the next #{@escalation_steps} steps."}
      ], step + @escalation_steps}
    else
      # 2. Shell command loops: same command prefix 3+ times in last 10 entries
      recent_shells = (recent_history |> Enum.take(-10))
                      |> Enum.filter(fn {tool, _, _} -> tool == "shell" end)
                      |> Enum.map(fn {_, input, _} -> String.slice(to_string(input), 0, 100) end)

      current_shells = executed
                       |> Enum.filter(fn {tc, _} -> tc.name == "shell" end)
                       |> Enum.map(fn {tc, _} -> String.slice(to_string(tc.input["command"]), 0, 100) end)

      shell_repeats =
        (recent_shells ++ current_shells)
        |> Enum.frequencies()
        |> Enum.filter(fn {_, count} -> count >= @stuck_shell_threshold end)
        |> Enum.map(fn {cmd, count} -> "\"#{String.slice(cmd, 0, 60)}...\" (#{count}x)" end)

      if shell_repeats != [] do
        Logger.warning("Stuck detection (shell): #{Enum.join(shell_repeats, ", ")}")
        {messages ++ [
          %{role: "user", content: "[System] WARNING: You are repeating the same shell command(s): #{Enum.join(shell_repeats, ", ")}. If it failed before, it will fail again. STOP and:\n1. Read the error output carefully\n2. Use `think` to analyze what's going wrong\n3. Try a fundamentally different approach\n\n[System] Escalating to a stronger model for the next #{@escalation_steps} steps."}
        ], step + @escalation_steps}
      else
        # 3. General repetition: same tool+input hash 3+ times
        current_sigs = Enum.map(executed, fn {tc, _} ->
          "#{tc.name}:#{:erlang.phash2(tc.input)}"
        end)

        recent_sigs = Enum.map(recent_history, fn {tool, input, _} ->
          "#{tool}:#{:erlang.phash2(input)}"
        end)

        repeated =
          (recent_sigs ++ current_sigs)
          |> Enum.frequencies()
          |> Enum.filter(fn {_, count} -> count >= @stuck_repeat_threshold end)

        if repeated != [] do
          Logger.warning("Stuck detection (repeat): #{length(repeated)} repeated tool calls")
          {messages ++ [
            %{role: "user", content: "[System] WARNING: You are repeating identical tool calls without making progress. This is wasting steps. STOP and use `think` to analyze why you're stuck, then try a different approach.\n\n[System] Escalating to a stronger model for the next #{@escalation_steps} steps."}
          ], step + @escalation_steps}
        else
          {messages, current_escalation}
        end
      end
    end
  end

  # --- Think Loop Detection ---

  @max_consecutive_thinks 3

  defp maybe_inject_think_warning(messages, executed, state) do
    tool_names = Enum.map(executed, fn {tc, _} -> tc.name end) |> Enum.uniq()
    think_only = tool_names == ["think"]
    prev_thinks = Map.get(state, :consecutive_thinks, 0)
    escalated_until = Map.get(state, :escalated_until, 0)

    consecutive = if think_only, do: prev_thinks + 1, else: 0

    if consecutive >= @max_consecutive_thinks do
      Logger.warning("Think loop detected: #{consecutive} consecutive think-only turns")
      step = state.step + 1
      {messages ++ [
        %{role: "user", content: "[System] WARNING: You have called `think` #{consecutive} times in a row without taking any other action. Stop thinking and ACT. Use a tool that changes state — `shell`, `write_file`, `edit_file`, `sub_agent` — or call `done` if you're finished. Do NOT call `think` again without an accompanying action tool.\n\n[System] Escalating to a stronger model for the next #{@escalation_steps} steps."}
      ], consecutive, step + @escalation_steps}
    else
      {messages, consecutive, escalated_until}
    end
  end

  # --- Drift Detection ---

  # Every @drift_check_interval steps, compare recent activity against the plan.
  # Uses a cheap LLM call to detect if the agent has wandered off-plan.
  @drift_check_interval 15

  @max_consecutive_drifts 2

  defp maybe_inject_drift_warning(%{step: step, plan: plan, history: history, depth: depth} = state)
       when depth == 0 and plan != nil and rem(step, @drift_check_interval) == 0 and step > 0 do
    recent =
      history
      |> Enum.take(-15)
      |> Enum.map(fn {tool, input, _result} -> "- [#{tool}] #{input}" end)
      |> Enum.join("\n")

    consecutive = Map.get(state, :consecutive_drifts, 0)

    case check_drift(plan, recent) do
      {:drifting, explanation} ->
        new_consecutive = consecutive + 1
        Logger.warning("Drift detected at step #{step} (#{new_consecutive} consecutive): #{String.slice(explanation, 0, 200)}")

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

  defp maybe_inject_drift_warning(state), do: {state.messages, Map.get(state, :consecutive_drifts, 0)}

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

  @file_size_warning_threshold 300  # lines

  defp maybe_inject_file_size_warning(messages, executed) do
    large_files =
      executed
      |> Enum.filter(fn {tc, result} ->
        tc.name == "write_file" and match?({:text, "File written" <> _}, result) and
          (tc.input["content"] || "") |> String.split("\n") |> length() > @file_size_warning_threshold
      end)
      |> Enum.map(fn {tc, _} ->
        lines = tc.input["content"] |> String.split("\n") |> length()
        "#{tc.input["path"]} (#{lines} lines)"
      end)

    if large_files != [] do
      files = Enum.join(large_files, ", ")
      Logger.warning("Large file warning: #{files}")
      messages ++ [
        %{role: "user", content: "[System] WARNING: You wrote large file(s): #{files}. Files over #{@file_size_warning_threshold} lines are harder to edit reliably — `edit_file` failures increase with file size. Consider splitting into smaller modules (e.g., one file per struct/component/handler). This is not optional cleanup — it directly prevents edit failures in later steps."}
      ]
    else
      messages
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
  # Accumulate cost in dollars directly, not raw tokens, since models have different prices.
  @sonnet_pricing %{input: 3.0, output: 15.0, cache_read: 0.3, cache_create: 3.75}
  @opus_pricing %{input: 15.0, output: 75.0, cache_read: 1.5, cache_create: 18.75}

  defp pricing_for(model) when is_binary(model) do
    if String.contains?(model, "opus"), do: @opus_pricing, else: @sonnet_pricing
  end

  defp accumulate_costs(costs, usage, model) do
    p = pricing_for(model)
    input = Map.get(usage, :input_tokens, 0)
    output = Map.get(usage, :output_tokens, 0)
    cache_read = Map.get(usage, :cache_read, 0)
    cache_create = Map.get(usage, :cache_create, 0)

    step_cost =
      input / 1_000_000 * p.input +
      output / 1_000_000 * p.output +
      cache_read / 1_000_000 * p.cache_read +
      cache_create / 1_000_000 * p.cache_create

    Map.update(costs, :total_dollars, step_cost, &(&1 + step_cost))
  end

  defp format_cost(%{total_dollars: dollars}) do
    :erlang.float_to_binary(dollars, decimals: 4)
  end

  defp format_cost(_costs), do: "0.0000"

  defp depth_prefix(0), do: ""
  defp depth_prefix(depth), do: String.duplicate("│ ", depth)
end
