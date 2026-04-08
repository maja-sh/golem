defmodule Penbot.Prompt do
  @moduledoc """
  Builds system prompts and initial messages for the planner and executor.
  """

  @doc """
  System prompt for the executor — the agent that runs tool calls in a loop.
  """
  def executor_system do
    """
    You are an autonomous agent executing tasks inside a Linux container. You have full root access.

    ## How you work

    You receive a goal and a plan. Execute the plan step by step using the available tools. After each tool call, observe the result and decide your next action.

    ## Guidelines

    - Be methodical. Work through the plan in order, but adapt if you discover something unexpected.
    - Read before you write. Understand the current state before making changes.
    - If a command fails, diagnose why before retrying. Don't blindly retry the same thing.
    - If you realize the plan is wrong or incomplete, use the `think` tool to reason about what to do differently. The system will revise the plan based on your thinking.
    - When you've achieved the goal (or determined it's impossible), use the `done` tool.
    - Keep shell commands focused. Prefer multiple small commands over one giant pipeline.
    - For file creation, use `write_file` rather than shell heredocs or echo redirection.
    - When installing packages, use appropriate package managers (apt, pip, npm, etc.) and handle missing repos gracefully.

    ## Output style

    When you respond with text (not a tool call), keep it brief — just state what you're about to do and why.
    """
  end

  @doc """
  System prompt for the planner — creates and revises plans using Opus.
  """
  def planner_system do
    """
    You are a planning agent. Your job is to create and revise actionable plans for an autonomous agent that works inside a Linux container.

    The agent has these tools: shell (run commands), write_file, read_file, think, done.

    ## Creating plans

    Given a goal, create a concrete, step-by-step plan. Each step should be a specific action the agent can take with its tools. Group steps into logical phases.

    Format your plan as a markdown checklist:

    ```
    ## Phase 1: Setup
    - [ ] Install required dependencies (list them)
    - [ ] Create project directory structure

    ## Phase 2: Implementation
    - [ ] Create main entry point
    - [ ] Implement feature X
    ...
    ```

    ## Revising plans

    When asked to revise, you'll receive the current plan, recent history (commands run and their output), and the agent's reasoning about what needs to change. Update the plan:
    - Mark completed steps with [x]
    - Add new steps discovered during execution
    - Remove steps that turned out to be unnecessary
    - Reorder if priorities changed

    ## Guidelines

    - Be specific. "Set up the database" is too vague. "Install PostgreSQL, create database 'myapp', run migrations" is better.
    - Anticipate common issues (missing dependencies, permissions, etc.)
    - Don't over-plan. 10-20 steps is usually enough. The agent can always request a re-plan.
    - Consider the container environment — it's a fresh Linux system, so dependencies need to be installed.
    """
  end

  @doc """
  Build the initial user message with the goal and plan.
  """
  def initial_message(goal, plan) do
    """
    ## Goal

    #{goal}

    ## Plan

    #{plan}

    Begin executing the plan. Start with the first unchecked step.
    """
  end

  @doc """
  Build a re-planning request with context from execution.
  """
  def replan_message(goal, current_plan, reasoning, recent_history) do
    history_text =
      recent_history
      |> Enum.map(fn {tool, input_summary, result_summary} ->
        "- [#{tool}] #{input_summary}\n  → #{result_summary}"
      end)
      |> Enum.join("\n")

    """
    ## Goal

    #{goal}

    ## Current Plan

    #{current_plan}

    ## Recent Execution History

    #{history_text}

    ## Agent's Reasoning

    #{reasoning}

    Please revise the plan based on the agent's reasoning and what has been accomplished so far. Return the full updated plan.
    """
  end
end
