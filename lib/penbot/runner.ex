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
  def run(goal, opts \\ []) do
    max_steps = opts[:max_steps] || Application.get_env(:penbot, :max_steps, 200)

    Logger.info("Starting run — goal: #{String.slice(goal, 0, 200)}")

    # Phase 1: Create a plan
    plan =
      case opts[:plan] do
        nil ->
          Logger.info("Creating plan with Opus...")

          case create_plan(goal) do
            {:ok, plan} ->
              Logger.info("Plan created:\n#{plan}")
              plan

            {:error, reason} ->
              Logger.error("Failed to create plan: #{inspect(reason)}")
              return_error(reason)
          end

        plan ->
          Logger.info("Using provided plan:\n#{plan}")
          plan
      end

    # Phase 2: Execute
    state = %{
      goal: goal,
      plan: plan,
      messages: [],
      step: 0,
      max_steps: max_steps,
      history: []
    }

    # Build initial messages
    system = Penbot.Prompt.executor_system()
    initial = Penbot.Prompt.initial_message(goal, plan)
    messages = [%{role: "user", content: initial}]
    state = %{state | messages: messages}

    loop(state, system)
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

  defp loop(%{step: step, max_steps: max} = _state, _system) when step >= max do
    Logger.warning("Hit max steps (#{max}). Stopping.")
    {:error, :max_steps_reached}
  end

  defp loop(state, system) do
    step = state.step + 1
    Logger.info("--- Step #{step} ---")

    model = Application.get_env(:penbot, :executor_model)
    max_tokens = Application.get_env(:penbot, :executor_max_tokens, 4096)
    tools = Penbot.Tools.all()

    # Trim messages if conversation is getting long
    messages = trim_messages(state.messages)

    case Penbot.Claude.call(messages,
           model: model,
           max_tokens: max_tokens,
           system: system,
           tools: tools
         ) do
      {:ok, %{tool_use: [tool_call | _]} = response} ->
        # Log any text the model produced alongside the tool call
        if response.text, do: Logger.info("  Agent: #{response.text}")

        # Execute the tool
        case Penbot.ToolHandler.execute(tool_call) do
          {:done, summary} ->
            Logger.info("Goal #{if summary.success, do: "achieved", else: "failed"}: #{summary.summary}")
            {:ok, summary}

          {:think, reasoning} ->
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
        end

      {:ok, %{text: text, tool_use: []}} ->
        # Model responded with text but no tool call — nudge it
        Logger.info("  Agent (no tool): #{text}")
        messages = state.messages ++ [
          %{role: "assistant", content: text},
          %{role: "user", content: "Continue executing the plan. Use a tool for your next action, or use `done` if the goal is achieved."}
        ]
        state = %{state | messages: messages, step: step}
        loop(state, system)

      {:error, reason} ->
        Logger.error("Claude API error: #{inspect(reason)}")

        # Retry once after a short delay
        if state[:retried] do
          {:error, reason}
        else
          Process.sleep(5_000)
          loop(%{state | retried: true}, system)
        end
    end
  end

  defp handle_replan(state, system, step, tool_call, reasoning) do
    Logger.info("  Re-planning with Opus...")

    # Take last 20 history entries for context
    recent = Enum.take(state.history, -20)

    case replan(state.goal, state.plan, reasoning, recent) do
      {:ok, new_plan} ->
        Logger.info("  Revised plan:\n#{new_plan}")

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
        Logger.error("  Re-planning failed: #{inspect(reason)}")
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

  defp maybe_add_text(blocks, nil), do: blocks
  defp maybe_add_text(blocks, text), do: blocks ++ [%{type: "text", text: text}]

  # Keep conversation manageable — trim middle turns when too long
  defp trim_messages(messages) when length(messages) <= 40, do: messages

  defp trim_messages(messages) do
    # Keep first 2 messages (initial context) and last 36
    {head, tail} = Enum.split(messages, 2)
    head ++ Enum.take(tail, -36)
  end

  defp summarize_input(%{name: "shell", input: %{"command" => cmd}}) do
    String.slice(cmd, 0, 100)
  end

  defp summarize_input(%{name: "write_file", input: %{"path" => path}}) do
    path
  end

  defp summarize_input(%{name: "read_file", input: %{"path" => path}}) do
    path
  end

  defp summarize_input(%{name: name, input: input}) do
    "#{name}: #{inspect(input) |> String.slice(0, 100)}"
  end

  defp return_error(reason) do
    {:error, reason}
  end
end
