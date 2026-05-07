defmodule Golem.Runner.Planner do
  @moduledoc """
  Plan creation and re-planning for the runner.

  Two entry points:

    * `create_plan/2` — runs the two-stage planner: Sonnet explores
      with read-only tools (`read_file`, `grep`, `glob`,
      `list_directory`, `web_search`, `web_fetch`), then signals
      `create_plan` and Opus produces the final structured plan.
    * `replan/4` — single-shot Opus call to revise the current plan
      after the executor calls `think(request_replan: true)`.

  Cost tracking, step-cap extension prompts, and AGENTS.md
  auto-discovery during exploration all live here. The shared
  helpers (`prompt_extend`, `accumulate_costs`, `format_cost`)
  are public on `Golem.Runner` so this module and the executor
  can both call them.
  """

  require Logger

  defp output, do: Golem.Output.current()

  @doc """
  Run the two-stage planner. Returns `{:ok, plan_text, costs}` or
  `{:error, reason}`.
  """
  def create_plan(goal, opts) do
    explore_model = Application.get_env(:golem, :executor_model)   # Sonnet for exploration
    plan_model = Application.get_env(:golem, :planner_model)       # Opus for final plan
    max_tokens = Application.get_env(:golem, :planner_max_tokens, 4096)
    thinking_budget = Application.get_env(:golem, :thinking_budget, 10_000)
    tools = Golem.Tools.for_planner()
    costs = %{total_dollars: 0.0}

    # Read AGENTS.md / CLAUDE.md from project roots for planner context
    agents_md_content = read_project_agents_md(opts[:agents_md])
    system = Golem.Prompt.planner_system(:explore, agents_md_content)

    attachment_blocks = opts[:attachment_blocks] || []

    messages = [
      %{role: "user", content: Golem.Prompt.planner_initial_message(goal, attachment_blocks)}
    ]

    planner_ctx = %{seen_agents_md: MapSet.new(), explore_model: explore_model, plan_model: plan_model}
    planner_loop(messages, explore_model, max_tokens, thinking_budget, tools, system, costs, planner_ctx, 1)
  end

  @doc """
  Single-shot replan triggered by `think(request_replan: true)`.
  Returns `{:ok, new_plan_text}` or `{:error, reason}`.
  """
  def replan(goal, current_plan, reasoning, recent_history) do
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

  # Read AGENTS.md content that was already built by the integration module
  defp read_project_agents_md(nil), do: nil
  defp read_project_agents_md(agents_md) when is_binary(agents_md), do: agents_md

  defp planner_loop(messages, model, max_tokens, thinking_budget, tools, system, costs, ctx, step) do
    max = Map.get(ctx, :extended_max_steps) || Application.get_env(:golem, :planner_max_steps, 75)

    if step > max do
      case Golem.Runner.prompt_extend(:planner, max, costs) do
        {:continue, new_max} ->
          ctx = Map.put(ctx, :extended_max_steps, new_max)
          planner_step(messages, model, max_tokens, thinking_budget, tools, system, costs, ctx, step)

        :abort ->
          {:error, :planner_max_steps}
      end
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
        costs = Golem.Runner.accumulate_costs(costs, response.usage, model)
        output().update_cost("$#{Golem.Runner.format_cost(costs)}")

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
        costs = Golem.Runner.accumulate_costs(costs, response.usage, model)
        output().update_cost("$#{Golem.Runner.format_cost(costs)}")
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
        costs = Golem.Runner.accumulate_costs(costs, response.usage, model)
        output().update_cost("$#{Golem.Runner.format_cost(costs)}")
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
end
