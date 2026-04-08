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
    prefix = depth_prefix(depth)

    Logger.info("#{prefix}========== RUN STARTED ==========")
    Logger.info("#{prefix}Goal: #{goal}")
    Logger.info("#{prefix}Depth: #{depth}, Max steps: #{max_steps}")

    result = do_run(goal, opts, max_steps, depth, prefix)

    case result do
      {:ok, %{success: true} = s} ->
        Logger.info("#{prefix}========== RUN SUCCEEDED ==========")
        Logger.info("#{prefix}#{s.summary}")

      {:ok, %{success: false} = s} ->
        Logger.info("#{prefix}========== RUN FAILED ==========")
        Logger.info("#{prefix}#{s.summary}")

      {:error, reason} ->
        Logger.error("#{prefix}========== RUN ERROR: #{inspect(reason)} ==========")
    end

    result
  end

  defp do_run(goal, opts, max_steps, depth, prefix) do
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
          history: []
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
      history: []
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

  defp loop(%{step: step, max_steps: max, prefix: prefix} = _state, _system) when step >= max do
    Logger.warning("#{prefix}Hit max steps (#{max}). Stopping.")
    {:error, :max_steps_reached}
  end

  defp loop(state, system) do
    step = state.step + 1
    p = state.prefix
    Logger.info("#{p}--- Step #{step}/#{state.max_steps} ---")

    model = Application.get_env(:penbot, :executor_model)
    max_tokens = Application.get_env(:penbot, :executor_max_tokens, 4096)
    tools = Penbot.Tools.for_depth(state.depth)

    # Trim messages if conversation is getting long
    messages = trim_messages(state.messages)

    case Penbot.Claude.call(messages,
           model: model,
           max_tokens: max_tokens,
           system: system,
           tools: tools
         ) do
      {:ok, %{tool_use: [tool_call | _]} = response} ->
        if response.text, do: Logger.info("#{p}  Agent: #{response.text}")

        # Execute the tool (pass depth for sub-agent spawning)
        case Penbot.ToolHandler.execute(tool_call, state.depth) do
          {:done, summary} ->
            {:ok, summary}

          {:think_replan, reasoning} ->
            # Re-plan with Opus
            handle_replan(state, system, step, tool_call, reasoning)

          {:continue, result} ->
            # Add the assistant's response and tool result to messages
            messages = append_tool_exchange(messages, response, tool_call, result)

            # Track in history
            input_summary = summarize_input(tool_call)
            result_summary = String.slice(result, 0, 200)
            history = state.history ++ [{tool_call.name, input_summary, result_summary}]

            state = %{state | messages: messages, step: step, history: history}
            loop(state, system)

          {:continue_with_image, %{text: text, base64: base64}} ->
            # Add tool result with image content block (for screenshots)
            messages = append_tool_exchange_with_image(messages, response, tool_call, text, base64)

            input_summary = summarize_input(tool_call)
            history = state.history ++ [{tool_call.name, input_summary, "[screenshot]"}]

            state = %{state | messages: messages, step: step, history: history}
            loop(state, system)
        end

      {:ok, %{text: text, tool_use: []}} ->
        Logger.info("#{p}  Agent (no tool): #{text}")
        messages = state.messages ++ [
          %{role: "assistant", content: text},
          %{role: "user", content: "Continue executing the plan. Use a tool for your next action, or use `done` if the goal is achieved."}
        ]
        state = %{state | messages: messages, step: step}
        loop(state, system)

      {:error, reason} ->
        Logger.error("#{p}  Claude API error: #{inspect(reason)}")

        # Retry once after a short delay
        if Map.get(state, :retried, false) do
          {:error, reason}
        else
          Process.sleep(5_000)
          loop(Map.put(state, :retried, true), system)
        end
    end
  end

  defp handle_replan(state, system, step, tool_call, reasoning) do
    Logger.info("#{state.prefix}  Re-planning with Opus...")

    # Take last 20 history entries for context
    recent = Enum.take(state.history, -20)

    case replan(state.goal, state.plan, reasoning, recent) do
      {:ok, new_plan} ->
        Logger.info("#{state.prefix}  Revised plan:\n#{new_plan}")

        # Add the think exchange to messages, then inject the new plan
        messages =
          append_tool_exchange(
            state.messages,
            %{text: nil, tool_use: [tool_call], thinking: nil, stop_reason: "tool_use"},
            tool_call,
            "Plan has been revised. See updated plan below."
          )

        messages =
          messages ++
            [%{role: "user", content: "## Revised Plan\n\n#{new_plan}\n\nContinue executing from where you left off."}]

        state = %{state | messages: messages, plan: new_plan, step: step}
        loop(state, system)

      {:error, reason} ->
        Logger.error("#{state.prefix}  Re-planning failed: #{inspect(reason)}")
        # Continue with old plan
        messages =
          append_tool_exchange(
            state.messages,
            %{text: nil, tool_use: [tool_call], thinking: nil, stop_reason: "tool_use"},
            tool_call,
            "Re-planning failed. Continue with the current plan."
          )

        state = %{state | messages: messages, step: step}
        loop(state, system)
    end
  end

  # --- Message Management ---

  # Build the assistant message content blocks and tool result for Claude's
  # tool_use conversation format
  defp append_tool_exchange(messages, response, tool_call, result) do
    # Assistant message with content blocks (text + tool_use)
    assistant_content =
      []
      |> maybe_add_text(response.text)
      |> Kernel.++([
        %{
          type: "tool_use",
          id: tool_call.id,
          name: tool_call.name,
          input: tool_call.input
        }
      ])

    # User message with tool_result
    tool_result = %{
      role: "user",
      content: [
        %{
          type: "tool_result",
          tool_use_id: tool_call.id,
          content: result
        }
      ]
    }

    messages ++
      [
        %{role: "assistant", content: assistant_content},
        tool_result
      ]
  end

  # Same as append_tool_exchange but includes an image in the tool result
  defp append_tool_exchange_with_image(messages, response, tool_call, text, base64) do
    assistant_content =
      []
      |> maybe_add_text(response.text)
      |> Kernel.++([
        %{
          type: "tool_use",
          id: tool_call.id,
          name: tool_call.name,
          input: tool_call.input
        }
      ])

    tool_result = %{
      role: "user",
      content: [
        %{
          type: "tool_result",
          tool_use_id: tool_call.id,
          content: [
            %{type: "text", text: text},
            %{
              type: "image",
              source: %{
                type: "base64",
                media_type: "image/png",
                data: base64
              }
            }
          ]
        }
      ]
    }

    messages ++
      [
        %{role: "assistant", content: assistant_content},
        tool_result
      ]
  end

  defp maybe_add_text(blocks, nil), do: blocks
  defp maybe_add_text(blocks, text), do: blocks ++ [%{type: "text", text: text}]

  # Keep conversation manageable — trim middle turns when too long.
  # Messages come in pairs (assistant tool_use + user tool_result),
  # so we must always keep an even number from the tail and never
  # split a pair. We keep only the first message (initial goal/plan).
  defp trim_messages(messages) when length(messages) <= 41, do: messages

  defp trim_messages(messages) do
    [first | rest] = messages
    # Keep last 38 messages (19 pairs of assistant+user)
    keep = min(38, length(rest))
    keep = keep - rem(keep, 2)
    [first | Enum.take(rest, -keep)]
  end

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

  defp summarize_input(%{name: name, input: input}) do
    "#{name}: #{inspect(input) |> String.slice(0, 100)}"
  end

  defp depth_prefix(0), do: ""
  defp depth_prefix(depth), do: String.duplicate("│ ", depth)

end
