defmodule Golem.Output do
  @moduledoc """
  Behaviour for output backends. Both TUI (terminal) and Discord Reporter
  implement this interface. The active backend is selected via
  `Application.get_env(:golem, :output_backend, Golem.TUI)`.
  """

  @callback init_display(run_id :: String.t(), goal :: String.t()) :: :ok
  @callback stop_display() :: :ok
  @callback planning(label :: String.t()) :: :ok
  @callback plan_created(plan :: String.t()) :: :ok
  @callback step_header(step :: integer(), max_steps :: integer(), cost :: String.t()) :: :ok
  @callback agent_text(text :: String.t() | nil) :: :ok
  @callback tool_call(name :: String.t(), detail :: String.t()) :: :ok
  @callback tool_result(name :: String.t(), detail :: String.t(), result :: String.t(), elapsed :: integer(), tokens :: any()) :: :ok
  @callback tool_error(name :: String.t(), detail :: String.t(), error :: String.t()) :: :ok
  @callback show_diff(path :: String.t(), old :: String.t(), new :: String.t()) :: :ok
  @callback set_progress(items :: list()) :: :ok
  @callback show_phase_costs(costs :: list()) :: :ok
  @callback sub_agent_status(goal :: String.t(), tool :: String.t(), detail :: String.t(), step :: integer(), max_steps :: integer()) :: :ok
  @callback run_complete(success :: boolean(), summary :: String.t()) :: :ok
  @callback run_paused(run_id :: String.t()) :: :ok
  @callback run_error(reason :: any()) :: :ok

  @doc """
  Returns the currently active output backend module.
  """
  def current do
    Application.get_env(:golem, :output_backend, Golem.TUI)
  end
end
