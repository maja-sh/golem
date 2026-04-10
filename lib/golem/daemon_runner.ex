defmodule Golem.DaemonRunner do
  @moduledoc """
  Manages the single active background job for daemon mode.
  Spawns runs in a Task, monitors completion, sends Discord notifications.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Public API ---

  @doc """
  Start a new run with the given goal. Returns {:ok, run_id} or {:error, :busy}.
  """
  def start_run(goal, opts \\ []) do
    GenServer.call(__MODULE__, {:start_run, goal, opts})
  end

  @doc """
  Resume a paused run. Returns {:ok, run_id} or {:error, :busy | :not_found}.
  """
  def resume_run(run_id, opts \\ []) do
    GenServer.call(__MODULE__, {:resume_run, run_id, opts})
  end

  @doc """
  Stop the current job gracefully (saves state).
  """
  def stop_run do
    GenServer.call(__MODULE__, :stop_run)
  end

  @doc """
  Get current status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    {:ok, %{status: :idle, run_id: nil, task_pid: nil, goal: nil, started_at: nil}}
  end

  @impl true
  def handle_call({:start_run, goal, opts}, _from, %{status: :idle} = state) do
    run_id = Golem.State.new_run_id()
    opts = Keyword.merge(opts, run_id: run_id, max_steps: opts[:max_steps] || 500)

    task = Task.async(fn ->
      Golem.Runner.run(goal, opts)
    end)

    Logger.info("[DaemonRunner] Started run #{run_id}: #{String.slice(goal, 0, 100)}")

    {:reply, {:ok, run_id},
     %{state | status: :running, run_id: run_id, task_pid: task.pid, goal: goal, started_at: DateTime.utc_now()}}
  end

  def handle_call({:start_run, _goal, _opts}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:resume_run, run_id, opts}, _from, %{status: :idle} = state) do
    case Golem.State.load(run_id) do
      {:ok, _saved} ->
        task = Task.async(fn ->
          Golem.Runner.resume(run_id, opts)
        end)

        Logger.info("[DaemonRunner] Resuming run #{run_id}")

        {:reply, {:ok, run_id},
         %{state | status: :running, run_id: run_id, task_pid: task.pid, goal: "resumed", started_at: DateTime.utc_now()}}

      {:error, reason} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:resume_run, _id, _opts}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:stop_run, _from, %{status: :running, task_pid: pid} = state) do
    if pid, do: send(pid, :stop_requested)
    Logger.info("[DaemonRunner] Stop requested for #{state.run_id}")
    {:reply, :ok, state}
  end

  def handle_call(:stop_run, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:status, :run_id, :goal, :started_at]), state}
  end

  @impl true
  def handle_info({ref, result}, %{status: :running} = state) when is_reference(ref) do
    # Task completed
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, %{success: true, summary: summary}} ->
        Logger.info("[DaemonRunner] Run #{state.run_id} succeeded: #{summary}")

      {:ok, %{success: false, summary: summary}} ->
        Logger.info("[DaemonRunner] Run #{state.run_id} failed: #{summary}")

      {:error, :max_steps_reached} ->
        Logger.info("[DaemonRunner] Run #{state.run_id} paused (max steps)")

      {:error, reason} ->
        Logger.error("[DaemonRunner] Run #{state.run_id} error: #{inspect(reason)}")
    end

    {:noreply, %{state | status: :idle, task_pid: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, %{status: :running} = state) do
    Logger.error("[DaemonRunner] Run #{state.run_id} crashed: #{inspect(reason)}")

    try do
      Golem.Discord.Reporter.run_error("Run crashed: #{inspect(reason)}")
    catch
      _, _ -> :ok
    end

    {:noreply, %{state | status: :idle, task_pid: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
