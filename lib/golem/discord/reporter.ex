defmodule Golem.Discord.Reporter do
  @moduledoc """
  Discord output backend implementing Golem.Output.

  Minimal notifications — only messages the user on:
  - run_complete (success/fail + cost)
  - run_error (crash/stuck)
  - run_paused (max steps)
  - ask_user (handled by Golem.Discord directly)

  Everything else is silent (logged to file only).
  """

  @behaviour Golem.Output

  require Logger

  # --- Output callbacks (mostly silent) ---

  @impl true
  def init_display(run_id, goal) do
    Logger.info("[Discord] Run started: #{run_id} — #{String.slice(goal, 0, 100)}")
    notify(run_id, "🔧 **Run started**\n#{String.slice(goal, 0, 500)}")
    :ok
  end

  @impl true
  def stop_display, do: :ok

  @impl true
  def planning(_label), do: :ok

  @impl true
  def plan_created(_plan), do: :ok

  @impl true
  def step_header(_step, _max_steps, _cost), do: :ok

  @impl true
  def agent_text(_text), do: :ok

  @impl true
  def tool_call(_name, _detail), do: :ok

  @impl true
  def tool_result(_name, _detail, _result, _elapsed, _tokens), do: :ok

  @impl true
  def tool_error(_name, _detail, _error), do: :ok

  @impl true
  def show_diff(_path, _old, _new), do: :ok

  @impl true
  def sub_agent_status(_goal, _tool, _detail, _step, _max_steps), do: :ok

  def sub_agent_start(_goal, _display_name \\ nil), do: :ok
  def sub_agent_result(_goal, _steps, _success), do: :ok

  @impl true
  def tool_batch_result(_results, _elapsed), do: :ok

  @impl true
  def update_cost(_cost), do: :ok

  @impl true
  def update_tokens(_count), do: :ok

  @impl true
  def set_progress(_items), do: :ok

  @impl true
  def show_phase_costs(_costs), do: :ok

  @impl true
  def pr_opened(_repo, _url), do: :ok

  @impl true
  def pr_skipped(_repo, _reason), do: :ok

  @impl true
  def run_complete(success, summary) do
    icon = if success, do: "✅", else: "❌"
    label = if success, do: "Goal achieved", else: "Goal not achieved"
    notify(nil, "#{icon} **#{label}**\n#{String.slice(summary, 0, 1500)}")
    :ok
  end

  @impl true
  def run_paused(run_id) do
    notify(run_id, "⏸️ **Paused** — hit max steps.\nResume: `resume #{run_id}`")
    :ok
  end

  @impl true
  def run_error(reason) do
    notify(nil, "⚠️ **Error**\n```\n#{inspect(reason) |> String.slice(0, 1500)}\n```")
    :ok
  end

  # Stubs for TUI-specific functions
  def stream_start, do: :ok
  def stream_text(_chunk), do: :ok
  def stream_end, do: :ok
  def format_elapsed(nil), do: "..."
  def format_elapsed(ms) when ms < 1000, do: "#{ms}ms"
  def format_elapsed(ms), do: "#{Float.round(ms / 1000, 1)}s"
  def format_tokens(nil), do: ""
  def format_tokens(0), do: ""
  def format_tokens(n) when n < 1000, do: "#{n} tokens"
  def format_tokens(n), do: "#{Float.round(n / 1000, 1)}k tokens"

  # --- Helpers ---

  defp notify(run_id, message) do
    try do
      channel_id = channel_id!()
      prefix = if run_id, do: "🔧 **Forge** [`#{run_id}`]\n", else: "🔧 **Forge**\n"
      Golem.Discord.send_message_to(channel_id, prefix <> message)
    rescue
      e -> Logger.error("[Discord Reporter] Failed to send: #{inspect(e)}")
    end
  end

  defp channel_id! do
    (System.get_env("DISCORD_CHANNEL_ID") || raise("DISCORD_CHANNEL_ID not set"))
    |> String.to_integer()
  end
end
