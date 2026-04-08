defmodule Penbot.Runner do
  @moduledoc """
  Main autonomous execution loop.

  1. Takes a goal
  2. Creates a plan (Opus)
  3. Executes steps in a loop (Sonnet with tools)
  4. Re-plans when the agent uses the `think` tool
  5. Terminates when done or max steps reached
  """

  require Logger

  @doc """
  Run the agent with the given goal. Blocks until completion.

  Options:
  - :max_steps — override max steps (default from config)
  - :plan — provide a pre-made plan instead of generating one

  Returns {:ok, summary} or {:error, reason}.
  """
  @sub_agent_max_steps 50

  def run(goal, opts \\ []) do
    max_steps = opts[:max_steps] || Application.get_env(:penbot, :max_steps, 200)
    depth = opts[:depth] || 0
    run_id = opts[:run_id] || Penbot.State.new_run_id()
    prefix = depth_prefix(depth)

    Logger.info("#{prefix}========== RUN STARTED (#{run_id}) ==========")
    Logger.info("#{prefix}Goal: #{goal}")
    Logger.info("#{prefix}Depth: #{depth}, Max steps: #{max_steps}")

    result = do_run(goal, opts, max_steps, depth, prefix, run_id)

    case result do
      {:ok, %{success: true} = s} ->
        Logger.info("#{prefix}========== RUN SUCCEEDED ==========")
        Logger.info("#{prefix}#{s.summary}")

      {:ok, %{success: false} = s} ->
        Logger.info("#{prefix}========== RUN FAILED ==========")
        Logger.info("#{prefix}#{s.summary}")

      {:error, :max_steps_reached} ->
        Logger.warning("#{prefix}========== RUN PAUSED (max steps) ==========")
        Logger.warning("#{prefix}Resume with: Penbot.resume(\"#{run_id}\")")

      {:error, reason} ->
        Logger.error("#{prefix}========== RUN ERROR: #{inspect(reason)} ==========")
    end

    result
  end

  @doc """
  Resume a previously paused run.
  """
  def resume(run_id, opts \\ []) do
    case Penbot.State.load(run_id) do
      {:ok, saved} ->
        extra_steps = opts[:max_steps] || Application.get_env(:penbot, :max_steps, 200)
        new_max = saved.step + extra_steps
        prefix = depth_prefix(saved.depth)

        Logger.info("#{prefix}========== RESUMING RUN #{run_id} ==========")
        Logger.info("#{prefix}Continuing from step #{saved.step}, new max: #{new_max}")

        state = %{
          goal: saved.goal,
          plan: saved.plan,
          messages: saved.messages,
          step: saved.step,
          max_steps: new_max,
          depth: saved.depth,
          prefix: prefix,
          history: saved.history,
          run_id: run_id
        }

        system = Penbot.Prompt.executor_system()
        result = loop(state, system)

        case result do
          {:ok, %{success: true} = s} ->
            Logger.info("#{prefix}========== RUN SUCCEEDED ==========")
            Logger.info("#{prefix}#{s.summary}")

          {:ok, %{success: false} = s} ->
            Logger.info("#{prefix}========== RUN FAILED ==========")
            Logger.info("#{prefix}#{s.summary}")

          {:error, :max_steps_reached} ->
            Logger.warning("#{prefix}========== RUN PAUSED (max steps) ==========")
            Logger.warning("#{prefix}Resume with: Penbot.resume(\"#{run_id}\")")

          {:error, reason} ->
            Logger.error("#{prefix}========== RUN ERROR: #{inspect(reason)} ==========")
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
          Logger.info("#{prefix}Planning with Opus...")
          create_plan(goal)

        plan ->
          {:ok, plan}
      end

    case plan_result do
      {:ok, plan} ->
        Logger.info("#{prefix}Plan:\n#{plan}")

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
          run_id: run_id
        }

        system = Penbot.Prompt.executor_system()
        initial = Penbot.Prompt.initial_message(goal, plan)
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

    system = Penbot.Prompt.sub_agent_system()

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
      costs: %{input: 0, output: 0, cache_read: 0, cache_create: 0}
    }

    result = loop(state, system)
    Logger.info("#{prefix}---------- SUB-AGENT FINISHED ----------")
    result
  end

  # --- Plan Creation ---

  defp create_plan(goal) do
    model = Application.get_env(:penbot, :planner_model)
    max_tokens = Application.get_env(:penbot, :planner_max_tokens, 4096)
    thinking_budget = Application.get_env(:penbot, :thinking_budget, 10_000)

    messages = [
      %{role: "user", content: "Create a plan for this goal:\n\n#{goal}"}
    ]

    case Penbot.Claude.call(messages,
           model: model,
           max_tokens: max_tokens,
           system: Penbot.Prompt.planner_system(),
           thinking_budget: thinking_budget
         ) do
      {:ok, %{text: text}} when is_binary(text) -> {:ok, text}
      {:ok, _} -> {:error, :no_plan_text}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replan(goal, current_plan, reasoning, recent_history) do
    model = Application.get_env(:penbot, :planner_model)
    max_tokens = Application.get_env(:penbot, :planner_max_tokens, 4096)
    thinking_budget = Application.get_env(:penbot, :thinking_budget, 10_000)

    message = Penbot.Prompt.replan_message(goal, current_plan, reasoning, recent_history)

    messages = [
      %{role: "user", content: message}
    ]

    case Penbot.Claude.call(messages,
           model: model,
           max_tokens: max_tokens,
           system: Penbot.Prompt.planner_system(),
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
    if run_id = Map.get(state, :run_id), do: Penbot.State.save(run_id, state)
    {:error, :max_steps_reached}
  end

  defp loop(state, system) do
    step = state.step + 1
    p = state.prefix
    # Make run_id available to tool handlers (for ask_user Discord messages)
    if run_id = Map.get(state, :run_id), do: Process.put(:penbot_run_id, run_id)
    costs = Map.get(state, :costs, %{input: 0, output: 0, cache_read: 0, cache_create: 0})
    Logger.info("#{p}--- Step #{step}/#{state.max_steps} | $#{format_cost(costs)} ---")

    model = Application.get_env(:penbot, :executor_model)
    max_tokens = Application.get_env(:penbot, :executor_max_tokens, 8000)
    thinking_budget = Application.get_env(:penbot, :thinking_budget, 10_000)
    tools = Penbot.Tools.for_depth(state.depth)

    # Trim messages if conversation is getting long
    messages = trim_messages(state.messages)

    case Penbot.Claude.call(messages,
           model: model,
           max_tokens: max_tokens,
           system: system,
           tools: tools,
           thinking_budget: thinking_budget
         ) do
      {:ok, %{tool_use: tool_calls} = response} when tool_calls != [] ->
        if response.text, do: Logger.info("#{p}  Agent: #{response.text}")
        costs = accumulate_costs(costs, response.usage, model)

        if length(tool_calls) > 1 do
          Logger.info("#{p}  #{length(tool_calls)} tool calls in this turn")
        end

        # Execute all tool calls, stopping early on done/think_replan
        case execute_tool_calls(tool_calls, state.depth) do
          {:done, summary, executed} ->
            messages = append_multi_tool_exchange(messages, response, executed)
            state = %{state | messages: messages, step: step, costs: costs, history: update_history(state.history, executed)}
            Logger.info("#{p}  Total cost: $#{format_cost(costs)}")
            maybe_save(state)
            {:ok, summary}

          {:think_replan, reasoning, executed} ->
            messages = append_multi_tool_exchange(messages, response, executed)
            state = %{state | messages: messages, step: step, costs: costs, history: update_history(state.history, executed)}
            last_tc = List.last(executed) |> elem(0)
            handle_replan(state, system, step, last_tc, reasoning)

          {:continue, executed} ->
            messages = append_multi_tool_exchange(messages, response, executed)
            state = %{state | messages: messages, step: step, costs: costs, history: update_history(state.history, executed)}
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
        {:error, reason}
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

  defp execute_tool_calls([tc | rest], depth, executed) do
    case Penbot.ToolHandler.execute(tc, depth) do
      {:done, summary} ->
        {:done, summary, Enum.reverse([{tc, {:text, "Goal completed."}} | executed])}

      {:think_replan, reasoning} ->
        {:think_replan, reasoning, Enum.reverse([{tc, {:text, "Re-planning requested."}} | executed])}

      {:continue, result} ->
        execute_tool_calls(rest, depth, [{tc, {:text, result}} | executed])

      {:continue_with_image, %{text: text, base64: base64}} ->
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

    # Summarize the old messages
    summary = compact_messages(old)

    # Rebuild: first message + summary + recent messages
    [first, %{role: "user", content: "[Conversation summary of earlier steps]\n\n#{summary}"}] ++ recent
  end

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
  defp summarize_input(%{name: "sub_agent", input: %{"goal" => g}}), do: String.slice(g, 0, 100)
  defp summarize_input(%{name: "ask_user", input: %{"question" => q}}), do: String.slice(q, 0, 100)

  defp summarize_input(%{name: name, input: input}) do
    "#{name}: #{inspect(input) |> String.slice(0, 100)}"
  end

  # Save state periodically (only for top-level runs, not sub-agents)
  defp maybe_save(%{depth: 0, run_id: run_id, step: step} = state) when not is_nil(run_id) do
    if Penbot.State.should_save?(step), do: Penbot.State.save(run_id, state)
  end
  defp maybe_save(_state), do: :ok

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
