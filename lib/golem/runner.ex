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
      errors: []
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

    model = Application.get_env(:golem, :executor_model)
    max_tokens = Application.get_env(:golem, :executor_max_tokens, 8000)
    thinking_budget = Application.get_env(:golem, :thinking_budget, 10_000)
    tools = Golem.Tools.for_depth(state.depth)

    # Trim messages if conversation is getting long
    messages = trim_messages(state.messages)

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
            Logger.info("#{p}  Total cost: $#{format_cost(costs)}")
            log_phase_costs(state)
            maybe_save(state)
            {:ok, summary}

          {:think_replan, reasoning, executed} ->
            messages = append_multi_tool_exchange(messages, response, executed)
            state = %{state | messages: messages, step: step, costs: costs, history: update_history(state.history, executed)}
            last_tc = List.last(executed) |> elem(0)
            handle_replan(state, system, step, last_tc, reasoning)

          {:continue, executed} ->
            messages = append_multi_tool_exchange(messages, response, executed)
            messages = maybe_inject_review(messages, executed)
            messages = maybe_inject_stuck_warning(messages, executed, state)
            new_errors = extract_errors(executed)
            errors = (errors ++ new_errors) |> Enum.uniq() |> Enum.take(-20)
            {phase_costs, last_completed} = track_phase_costs(executed, costs, state)
            state = %{state | messages: messages, step: step, costs: costs, errors: errors,
                       phase_costs: phase_costs, last_completed: last_completed,
                       history: update_history(state.history, executed)}
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

  # Execute multiple tool calls sequentially. Stops early on :done or :think_replan.
  # Returns {action, list_of_{tool_call, result}} where action is :continue, {:done, summary}, or {:think_replan, reasoning}
  defp execute_tool_calls(tool_calls, depth) do
    execute_tool_calls(tool_calls, depth, [])
  end

  defp execute_tool_calls([], _depth, executed) do
    {:continue, Enum.reverse(executed)}
  end

  @silent_tools ~w(update_progress)

  defp execute_tool_calls([tc | rest], depth, executed) do
    detail = summarize_input(tc)
    silent = tc.name in @silent_tools

    if not silent, do: output().tool_call(tc.name, detail)

    start = System.monotonic_time(:millisecond)

    case Golem.ToolHandler.execute(tc, depth) do
      {:done, summary} ->
        elapsed = System.monotonic_time(:millisecond) - start
        output().tool_result(tc.name, detail, summary.summary, elapsed, nil)
        {:done, summary, Enum.reverse([{tc, {:text, "Goal completed."}} | executed])}

      {:think_replan, reasoning} ->
        elapsed = System.monotonic_time(:millisecond) - start
        output().tool_result(tc.name, detail, "Re-planning...", elapsed, nil)
        {:think_replan, reasoning, Enum.reverse([{tc, {:text, "Re-planning requested."}} | executed])}

      {:continue, result} ->
        elapsed = System.monotonic_time(:millisecond) - start
        is_error = String.starts_with?(result, "[error]") or String.starts_with?(result, "[exit code")

        if not silent do
          if is_error do
            output().tool_error(tc.name, detail, result)
          else
            output().tool_result(tc.name, detail, result, elapsed, nil)
          end
        end
        execute_tool_calls(rest, depth, [{tc, {:text, result}} | executed])

      {:continue_with_image, %{text: text, base64: base64}} ->
        elapsed = System.monotonic_time(:millisecond) - start
        if not silent, do: output().tool_result(tc.name, detail, text, elapsed, nil)
        execute_tool_calls(rest, depth, [{tc, {:image, text, base64}} | executed])
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
    # Extract a readable summary from old tool exchanges
    text =
      messages
      |> Enum.chunk_every(2)
      |> Enum.map(fn
        [%{role: "assistant", content: content}, %{role: "user"} = user_msg] ->
          # Extract tool name and result
          tool_name = extract_tool_name(content)
          result = extract_result_text(user_msg)
          "- [#{tool_name}] → #{String.slice(result, 0, 150)}"

        [%{role: "assistant", content: content}] ->
          text = if is_binary(content), do: content, else: "[tool call]"
          "- Agent: #{String.slice(text, 0, 150)}"

        [%{role: "user", content: content}] ->
          text = if is_binary(content), do: content, else: "[system]"
          "- System: #{String.slice(text, 0, 150)}"

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    # If the summary itself is manageable, just use it directly
    # No need for an LLM call — structured extraction is cheaper and faster
    if byte_size(text) > 10_000 do
      "[#{length(messages)} earlier messages truncated]\n" <>
        (text |> String.slice(0, 8_000))
    else
      text
    end
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
      Logger.warning("Stuck detection: #{Enum.join(stuck_files, ", ")}")
      messages ++ [
        %{role: "user", content: "[System] WARNING: You appear to be stuck in an edit loop on: #{Enum.join(stuck_files, ", ")}. You've been editing the same file(s) repeatedly without making progress. STOP editing and do one of these instead:\n1. Use `think` to step back and analyze WHY your edits keep failing\n2. Read the FULL file to understand the actual current state\n3. Try a completely different approach (e.g. rewrite the whole file instead of patching)\n4. Move on to a different task and come back to this later\n\nDo NOT make another edit to the same file without first explaining your new approach via `think`."}
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
