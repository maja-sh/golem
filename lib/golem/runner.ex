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
          costs: Map.get(saved, :costs, %{input: 0, output: 0, cache_read: 0, cache_create: 0}),
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
          costs: %{input: 0, output: 0, cache_read: 0, cache_create: 0},
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
  """
  def run_sub_agent(goal, context, parent_depth) do
    depth = parent_depth + 1
    prefix = depth_prefix(depth)
    Logger.info("#{prefix}---------- SUB-AGENT SPAWNED ----------")
    Logger.info("#{prefix}Goal: #{String.slice(goal, 0, 500)}")

    system = Golem.Prompt.sub_agent_system()

    initial_content =
      if context && context != "" do
        "## Goal\n\n#{goal}\n\n## Context from parent agent\n\n#{context}\n\nBegin working on this goal."
      else
        "## Goal\n\n#{goal}\n\nBegin working on this goal."
      end

    state = %{
      goal: goal,
      plan: nil,
      messages: [%{role: "user", content: initial_content}],
      step: 0,
      max_steps: @sub_agent_max_steps,
      depth: depth,
      prefix: prefix,
      history: [],
      costs: %{input: 0, output: 0, cache_read: 0, cache_create: 0},
      errors: [],
      phase_costs: [],
      last_completed: 0
    }

    result = loop(state, system)
    Logger.info("#{prefix}---------- SUB-AGENT FINISHED ----------")
    result
  end

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
    # Check for stop signal (from DaemonRunner.stop_run)
    if check_stop() do
      Logger.info("Stop requested — saving state")
      if run_id = Map.get(state, :run_id), do: Golem.State.save(run_id, state)
      {:error, :stopped}
    else
      do_loop(state)
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
    costs = Map.get(state, :costs, %{input: 0, output: 0, cache_read: 0, cache_create: 0})
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

    # Trim messages if conversation is getting long
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

        # Execute all tool calls, stopping early on done/think_replan
        case execute_tool_calls(tool_calls, state.depth) do
          {:done, summary, executed} ->
            messages = append_multi_tool_exchange(messages, response, executed)
            state = %{state | messages: messages, step: step, costs: costs, history: update_history(state.history, executed)}

            case maybe_verify(summary, state) do
              {:accept, state} ->
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
            new_errors = extract_errors(executed)
            errors = (errors ++ new_errors) |> Enum.uniq() |> Enum.take(-20)
            {phase_costs, last_completed} = track_phase_costs(executed, costs, state)
            state = %{state | messages: messages, step: step, costs: costs, errors: errors,
                       phase_costs: phase_costs, last_completed: last_completed,
                       history: update_history(state.history, executed)}
            state = Map.put(state, :escalated_until, escalated_until)
            {messages, consecutive_drifts} = maybe_inject_drift_warning(state)
            state = %{state | messages: messages}
            state = Map.put(state, :consecutive_drifts, consecutive_drifts)
            maybe_save(state)
            loop(state, system)
        end

      {:ok, %{text: text, tool_use: []} = response} ->
        Logger.info("#{p}  Agent (no tool): #{text}")
        costs = accumulate_costs(costs, response.usage, model)
        messages = state.messages ++ [
          %{role: "assistant", content: text},
          %{role: "user", content: "Continue executing the plan. Use a tool for your next action, or use `done` if the goal is achieved."}
        ]
        state = %{state | messages: messages, step: step, costs: costs}
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

  defp execute_tool_calls(tool_calls, depth) do
    batches = partition_batches(tool_calls)
    execute_batches(batches, depth, [], depth == 0)
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

  defp execute_batches([], _depth, executed, _show), do: {:continue, executed}

  defp execute_batches([batch | rest], depth, executed, show) do
    if length(batch) > 1 do
      results = execute_concurrent_batch(batch, depth, show)
      execute_batches(rest, depth, executed ++ results, show)
    else
      [tc] = batch

      case execute_single_tool(tc, depth, show) do
        {:done, summary, entry} ->
          {:done, summary, executed ++ [entry]}

        {:think_replan, reasoning, entry} ->
          {:think_replan, reasoning, executed ++ [entry]}

        {:continue, entry} ->
          execute_batches(rest, depth, executed ++ [entry], show)
      end
    end
  end

  # Run a batch of read-only tools concurrently using Task.async.
  defp execute_concurrent_batch(batch, depth, show) do
    # Show all tool_call headers first
    if show do
      Enum.each(batch, fn tc ->
        silent = tc.name in @silent_tools
        if not silent, do: output().tool_call(tc.name, summarize_input(tc))
      end)
    end

    # Execute all in parallel
    tasks =
      Enum.map(batch, fn tc ->
        Task.async(fn ->
          start = System.monotonic_time(:millisecond)
          result = Golem.ToolHandler.execute(tc, depth)
          elapsed = System.monotonic_time(:millisecond) - start
          {tc, result, elapsed}
        end)
      end)

    results = Task.await_many(tasks, :infinity)

    # Report results to TUI in order (only at depth 0)
    Enum.map(results, fn {tc, result, elapsed} ->
      detail = summarize_input(tc)
      silent = tc.name in @silent_tools

      case result do
        {:continue, text} ->
          is_error = String.starts_with?(text, "[error]") or String.starts_with?(text, "[exit code")

          if show and not silent do
            if is_error,
              do: output().tool_error(tc.name, detail, text),
              else: output().tool_result(tc.name, detail, text, elapsed, nil)
          end

          {tc, {:text, text}}

        {:continue_with_image, %{text: text, base64: base64}} ->
          if show and not silent, do: output().tool_result(tc.name, detail, text, elapsed, nil)
          {tc, {:image, text, base64}}
      end
    end)
  end

  # Execute a single tool call (may be any type, including done/think_replan).
  defp execute_single_tool(tc, depth, show) do
    detail = summarize_input(tc)
    silent = tc.name in @silent_tools
    if show and not silent, do: output().tool_call(tc.name, detail)

    start = System.monotonic_time(:millisecond)

    case Golem.ToolHandler.execute(tc, depth) do
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

  defp handle_replan(state, system, step, _tool_call, reasoning) do
    Logger.info("#{state.prefix}  Re-planning with Opus...")
    if state.depth == 0, do: output().planning("Re-planning with Opus...")

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
        loop(state, system)

      {:error, reason} ->
        Logger.error("#{state.prefix}  Re-planning failed: #{inspect(reason)}")

        messages =
          state.messages ++
            [%{role: "user", content: "Re-planning failed. Continue with the current plan."}]

        state = %{state | messages: messages, step: step}
        loop(state, system)
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

    {:reject, %{state | messages: messages, done_rejections: rejections}}
  end

  # --- Microcompaction ---

  # Selectively clear bulky tool results from older messages.
  # Keeps the last @micro_keep_recent messages untouched. For older messages,
  # replaces large tool_result content with "[cleared]" — the tool name and
  # structure are preserved so the model still knows what happened.
  @micro_keep_recent 10
  @micro_clearable_tools ~w(shell read_file grep glob web_search web_fetch list_directory browse)
  @micro_min_size 500

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

  # --- Message Management ---

  # Keep conversation manageable. When messages exceed the threshold,
  # summarize older turns into a compact recap using a cheap LLM call.
  # This preserves context far better than just dropping messages.
  @compact_threshold 40
  @compact_keep_recent 20

  defp trim_messages(messages) when length(messages) <= @compact_threshold, do: messages

  defp trim_messages(messages) do
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

    # Rebuild: first message + assistant ack + summary + recent messages
    # The assistant message prevents consecutive user messages (goal + summary)
    [
      first,
      %{role: "assistant", content: "I'll continue working on this goal."},
      %{role: "user", content: "[Conversation summary of earlier steps]\n\n#{summary}\n\nContinue from where you left off."}
    ] ++ recent
  end

  defp drop_leading_user_messages([%{role: "user"} | rest]) do
    drop_leading_user_messages(rest)
  end
  defp drop_leading_user_messages(messages), do: messages

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
  The agent is working toward a goal inside a Linux container.

  Produce a structured summary that preserves the CONTEXT the agent needs to continue \
  effectively. Focus on WHAT matters, not the raw tool calls.

  Format your summary with these sections:

  ## Accomplished
  What has been built, installed, or completed so far. List files created/modified.

  ## Current State
  Where things stand right now — what's working, what's partially done.

  ## Key Decisions
  Important choices made (tech stack, architecture, approach). The agent needs to \
  remember WHY it chose approach A over B.

  ## Errors & Fixes
  Problems encountered and how they were resolved. Only include if the fix is \
  non-obvious and the error could recur.

  Keep each section to 3-5 bullet points. Be specific (include file paths, command names, \
  package versions) but concise. Total summary should be under 500 words.

  CRITICAL: Respond with ONLY the summary text. Do NOT use any tools. Do NOT add commentary.
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
           max_tokens: 2_000,
           system: @compaction_prompt
         ) do
      {:ok, %{text: text}} when is_binary(text) and text != "" ->
        {:ok, text}

      _ ->
        {:error, :no_summary}
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

  @escalation_steps 5

  defp maybe_inject_stuck_warning(messages, executed, state) do
    # Count how many times each file was edited in recent history
    recent_history = Enum.take(state.history, -15)
    current_edits = Enum.filter(executed, fn {tc, _} -> tc.name in ["edit_file", "write_file"] end)
                    |> Enum.map(fn {tc, _} -> tc.input["path"] end)
                    |> Enum.reject(&is_nil/1)

    recent_edits = Enum.filter(recent_history, fn {tool, _, _} -> tool in ["edit_file", "write_file"] end)
                   |> Enum.map(fn {_, path, _} -> path end)

    all_edits = recent_edits ++ current_edits

    # Find files edited more than 4 times recently
    stuck_files =
      all_edits
      |> Enum.frequencies()
      |> Enum.filter(fn {_, count} -> count >= 4 end)
      |> Enum.map(fn {file, count} -> "#{Path.basename(file)} (#{count} edits)" end)

    if stuck_files != [] do
      Logger.warning("Stuck detection: #{Enum.join(stuck_files, ", ")} — escalating to Opus for #{@escalation_steps} steps")
      step = state.step + 1
      {messages ++ [
        %{role: "user", content: "[System] WARNING: You appear to be stuck in an edit loop on: #{Enum.join(stuck_files, ", ")}. You've been editing the same file(s) repeatedly without making progress. STOP editing and do one of these instead:\n1. Use `think` to step back and analyze WHY your edits keep failing\n2. Read the FULL file to understand the actual current state\n3. Try a completely different approach (e.g. rewrite the whole file instead of patching)\n4. Move on to a different task and come back to this later\n\nDo NOT make another edit to the same file without first explaining your new approach via `think`.\n\n[System] Escalating to a stronger model for the next #{@escalation_steps} steps to help you break out of this loop."}
      ], step + @escalation_steps}
    else
      {messages, Map.get(state, :escalated_until, 0)}
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
  @default_pricing %{input: 3.0, output: 15.0, cache_read: 0.3, cache_create: 3.75}

  defp accumulate_costs(costs, usage, _model) do
    %{
      input: costs.input + Map.get(usage, :input_tokens, 0),
      output: costs.output + Map.get(usage, :output_tokens, 0),
      cache_read: costs.cache_read + Map.get(usage, :cache_read, 0),
      cache_create: costs.cache_create + Map.get(usage, :cache_create, 0)
    }
  end

  defp format_cost(costs) do
    p = @default_pricing
    dollars =
      costs.input / 1_000_000 * p.input +
      costs.output / 1_000_000 * p.output +
      costs.cache_read / 1_000_000 * p.cache_read +
      costs.cache_create / 1_000_000 * p.cache_create

    :erlang.float_to_binary(dollars, decimals: 4)
  end

  defp depth_prefix(0), do: ""
  defp depth_prefix(depth), do: String.duplicate("│ ", depth)
end
