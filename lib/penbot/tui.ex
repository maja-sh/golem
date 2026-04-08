defmodule Penbot.TUI do
  @moduledoc """
  Terminal UI using Owl.LiveScreen.
  Shows a live-updating display with progress items, step count, cost, and current action.
  """

  require Logger

  @doc """
  Initialize the TUI display. Call once at the start of a run.
  """
  def init(run_id, goal) do
    # Ensure Owl application is started
    Application.ensure_all_started(:owl)

    # Suppress console logger so it doesn't interleave with blocks.
    # The file logger (penbot.log) still captures everything.
    Logger.configure(level: :warning)

    Owl.LiveScreen.add_block(:header,
      state: %{run_id: run_id, goal: goal},
      render: &render_header/1
    )

    Owl.LiveScreen.add_block(:status,
      state: %{step: 0, max_steps: 0, cost: "$0.0000", elapsed: 0, action: "starting..."},
      render: &render_status/1
    )

    Owl.LiveScreen.add_block(:progress,
      state: [],
      render: &render_progress/1
    )

    Owl.LiveScreen.add_block(:action,
      state: %{tool: nil, detail: nil},
      render: &render_action/1
    )
  end

  @doc """
  Update the status bar with step count, cost, etc.
  """
  def update_status(step, max_steps, cost_str) do
    Owl.LiveScreen.update(:status, %{
      step: step,
      max_steps: max_steps,
      cost: cost_str,
      action: nil
    })
  end

  @doc """
  Update the current action being performed.
  """
  def update_action(tool, detail \\ nil) do
    Owl.LiveScreen.update(:action, %{tool: tool, detail: detail})
  end

  @doc """
  Clear the current action (between steps).
  """
  def clear_action do
    Owl.LiveScreen.update(:action, %{tool: nil, detail: nil})
  end

  @doc """
  Set the full progress list. Each item is %{text, status} where
  status is :pending, :in_progress, or :completed.
  """
  def set_progress(items) do
    Owl.LiveScreen.update(:progress, items)
  end

  @doc """
  Clean up and flush the display.
  """
  def stop do
    try do
      Owl.LiveScreen.flush()
    catch
      :exit, _ -> :ok
    end

    restore_logger()
  end

  # --- Renderers ---

  defp render_header(%{run_id: run_id, goal: goal}) do
    goal_short = String.slice(goal, 0, 70)
    goal_display = if String.length(goal) > 70, do: goal_short <> "...", else: goal_short

    [
      Owl.Data.tag("╔══ Forge ", :cyan),
      Owl.Data.tag(run_id, [:faint, :cyan]),
      Owl.Data.tag(" ══", :cyan),
      "\n",
      Owl.Data.tag("║ ", :cyan),
      Owl.Data.tag(goal_display, :white)
    ]
  end

  defp render_status(%{step: step, max_steps: max, cost: cost}) do
    bar_width = 20
    pct = if max > 0, do: min(step / max, 1.0), else: 0
    filled = round(pct * bar_width)
    empty = bar_width - filled

    [
      Owl.Data.tag("╠══ ", :cyan),
      Owl.Data.tag(String.duplicate("█", filled), :green),
      Owl.Data.tag(String.duplicate("░", empty), :faint),
      " ",
      Owl.Data.tag("#{step}/#{max}", :white),
      Owl.Data.tag(" │ ", :faint),
      Owl.Data.tag(cost, :yellow)
    ]
  end

  defp render_progress([]) do
    [Owl.Data.tag("║ ", :cyan), Owl.Data.tag("No progress items yet", :faint)]
  end

  defp render_progress(items) do
    items
    |> Enum.map(fn item ->
      {icon, color} =
        case item.status do
          :completed -> {"✓", :green}
          :in_progress -> {"→", :yellow}
          :pending -> {" ", :faint}
        end

      [
        Owl.Data.tag("║ ", :cyan),
        Owl.Data.tag("[#{icon}]", color),
        " ",
        Owl.Data.tag(item.text, if(item.status == :pending, do: :faint, else: :white))
      ]
    end)
    |> Enum.intersperse("\n")
    |> List.flatten()
  end

  defp render_action(%{tool: nil}), do: []

  defp render_action(%{tool: tool, detail: detail}) do
    detail_text = if detail, do: " #{String.slice(detail, 0, 60)}", else: ""

    [
      Owl.Data.tag("╚══ ", :cyan),
      Owl.Data.tag("[#{tool}]", :magenta),
      Owl.Data.tag(detail_text, :faint)
    ]
  end

  defp restore_logger do
    Logger.configure(level: :info)
  end
end
