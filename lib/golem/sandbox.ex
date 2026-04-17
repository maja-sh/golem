defmodule Golem.Sandbox do
  @moduledoc """
  Manages shell access to a podman container via an interactive bash port.

  Commands are wrapped in sentinels for reliable output parsing.
  Supports file read/write via podman cp and container reset.
  """

  use GenServer
  require Logger

  @max_output_bytes 200_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Execute a shell command in the container. Returns {:ok, %{output, exit_code}} or {:error, reason}.

  Options:
  - `:timeout` — hard time limit (default from config, typically 900s)
  - `:stall_timeout` — max silence before returning stall error (default 60s, `:infinity` to disable)
  """
  def exec(command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, default_timeout())
    stall_timeout = Keyword.get(opts, :stall_timeout, default_stall_timeout())
    GenServer.call(__MODULE__, {:exec, command, timeout, stall_timeout}, timeout + 5_000)
  catch
    :exit, _ -> {:error, :timeout}
  end

  @doc """
  Write a file into the container.
  """
  def write_file(container_path, content) do
    GenServer.call(__MODULE__, {:write_file, container_path, content}, 15_000)
  catch
    :exit, _ -> {:error, :timeout}
  end

  @doc """
  Read a file from the container.
  """
  def read_file(container_path) do
    container = Application.get_env(:golem, :container, "golem-vm")
    runtime = Golem.Runtime.executable()

    # Use podman cp for reads — bypasses the sentinel-based exec which
    # is slow for large files (375KB JSON was timing out at 30s)
    tmp = System.tmp_dir!() |> Path.join("golem_read_#{:crypto.strong_rand_bytes(4) |> Base.encode16()}")

    case System.cmd(runtime, ["cp", "#{container}:#{container_path}", tmp], stderr_to_stdout: true) do
      {_, 0} ->
        content = File.read!(tmp)
        File.rm(tmp)
        {:ok, content}

      {err, _} ->
        File.rm(tmp)
        {:error, String.trim(err)}
    end
  end

  @doc """
  Reset the container — stop, remove, and recreate from image.
  """
  def reset do
    GenServer.call(__MODULE__, :reset, 60_000)
  catch
    :exit, _ -> {:error, :timeout}
  end

  @doc """
  Check if the container is running.
  """
  def status do
    GenServer.call(__MODULE__, :status, 5_000)
  catch
    :exit, _ -> {:error, :timeout}
  end

  # --- Server ---

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    container = Application.get_env(:golem, :container, "golem-vm")
    Logger.debug("Sandbox initialized, container: #{container}")
    {:ok, %{port: nil, container: container, buffer: "", mode: :idle, cwd: nil, stall_ms: nil}}
  end

  @impl true
  def handle_call({:exec, command, timeout, stall_timeout}, from, %{mode: :idle} = state) do
    state = ensure_port(state)

    case state.port do
      nil ->
        {:reply, {:error, :port_not_available}, state}

      port ->
        ref = :crypto.strong_rand_bytes(8) |> Base.encode16()

        # Source .bashrc for PATH, then cd to persist working directory
        cd_prefix = if state.cwd, do: "cd #{escape(state.cwd)} 2>/dev/null; ", else: ""
        wrapped =
          "source ~/.bashrc 2>/dev/null; echo '---CMD_START_#{ref}---'; #{cd_prefix}#{command} 2>&1; __exit=$?; echo ''; echo \"---CWD_#{ref}_$(pwd)---\"; echo \"---CMD_END_#{ref}_${__exit}---\"\n"

        Port.command(port, wrapped)
        timer = Process.send_after(self(), {:exec_timeout, ref}, timeout)
        stall_timer = start_stall_timer(ref, stall_timeout)
        {:noreply, %{state | buffer: "", mode: {:exec, ref, from, timer, stall_timer}, stall_ms: stall_timeout}}
    end
  end

  def handle_call({:exec, _command, _timeout, _stall_timeout}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:write_file, container_path, content}, _from, state) do
    result = do_write_file(state.container, container_path, content)
    {:reply, result, state}
  end

  def handle_call(:reset, _from, state) do
    # Close existing port
    state = close_port(state)
    container = state.container

    Logger.info("Resetting container #{container}...")

    # Stop and remove
    System.cmd(Golem.Runtime.cmd(), ["stop", "-t", "2", container], stderr_to_stdout: true)
    System.cmd(Golem.Runtime.cmd(), ["rm", "-f", container], stderr_to_stdout: true)

    # Recreate from image with persistent volume
    case System.cmd(Golem.Runtime.cmd(), [
           "run", "-d",
           "--name", container,
           "--privileged",
           "-v", "golem-data:/home/agent",
           "#{container}:latest"
         ], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("Container #{container} reset successfully")
        {:reply, :ok, %{state | port: nil, buffer: "", mode: :idle}}

      {output, code} ->
        Logger.error("Container reset failed (#{code}): #{output}")
        {:reply, {:error, "reset failed: #{output}"}, %{state | port: nil, buffer: "", mode: :idle}}
    end
  end

  def handle_call(:status, _from, state) do
    case System.cmd(Golem.Runtime.cmd(), ["inspect", "-f", "{{.State.Status}}", state.container],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:reply, {:ok, String.trim(output)}, state}
      {output, _} -> {:reply, {:error, String.trim(output)}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data

    buffer =
      if byte_size(buffer) > @max_output_bytes do
        "[output truncated]\n" <>
          binary_part(buffer, byte_size(buffer) - @max_output_bytes, @max_output_bytes)
      else
        buffer
      end

    case state.mode do
      {:exec, ref, from, timer, stall_timer} ->
        # Broadcast last few lines to TUI for live output display
        broadcast_output(buffer, ref)

        case parse_sentinel(buffer, ref) do
          {:ok, output, exit_code, new_cwd} ->
            Process.cancel_timer(timer)
            cancel_stall_timer(stall_timer)
            Golem.TUI.clear_live_output()
            GenServer.reply(from, {:ok, %{output: output, exit_code: exit_code}})
            {:noreply, %{state | buffer: "", mode: :idle, cwd: new_cwd || state.cwd, stall_ms: nil}}

          :incomplete ->
            # Reset stall timer — we got output, so the command isn't stalled
            cancel_stall_timer(stall_timer)
            new_stall_timer = start_stall_timer(ref, state.stall_ms)
            {:noreply, %{state | buffer: buffer, mode: {:exec, ref, from, timer, new_stall_timer}}}
        end

      :idle ->
        {:noreply, %{state | buffer: ""}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Sandbox port exited with status #{status}")

    case state.mode do
      {:exec, _ref, from, timer, stall_timer} ->
        Process.cancel_timer(timer)
        cancel_stall_timer(stall_timer)
        GenServer.reply(from, {:error, :port_died})

      :idle ->
        :ok
    end

    {:noreply, %{state | port: nil, buffer: "", mode: :idle, stall_ms: nil}}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    if state.port != nil and pid == state.port do
      Logger.warning("Sandbox port process exited: #{inspect(reason)}")

      case state.mode do
        {:exec, _ref, from, timer, stall_timer} ->
          Process.cancel_timer(timer)
          cancel_stall_timer(stall_timer)
          GenServer.reply(from, {:error, :port_died})

        :idle ->
          :ok
      end

      {:noreply, %{state | port: nil, buffer: "", mode: :idle, stall_ms: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:exec_timeout, ref}, state) do
    case state.mode do
      {:exec, ^ref, from, _timer, stall_timer} ->
        cancel_stall_timer(stall_timer)
        Logger.warning("Sandbox exec timed out, partial output: #{byte_size(state.buffer)} bytes")
        GenServer.reply(from, {:error, {:timeout, state.buffer}})
        {:noreply, %{state | buffer: "", mode: :idle, stall_ms: nil}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:stall_timeout, ref}, state) do
    case state.mode do
      {:exec, ^ref, from, timer, _stall_timer} ->
        Process.cancel_timer(timer)
        stall_s = if is_integer(state.stall_ms), do: div(state.stall_ms, 1000), else: "?"
        Logger.warning("Sandbox exec stalled — no output for #{stall_s}s, partial: #{byte_size(state.buffer)} bytes")
        GenServer.reply(from, {:error, {:stall_timeout, state.buffer}})
        {:noreply, %{state | buffer: "", mode: :idle, stall_ms: nil}}

      _ ->
        {:noreply, state}
    end
  end

  # --- Private ---

  defp ensure_port(%{port: nil, container: container} = state) do
    podman = System.find_executable(Golem.Runtime.cmd())

    if podman do
      try do
        port =
          Port.open({:spawn_executable, podman}, [
            {:args, ["exec", "-i", "-u", "root", container, "/bin/bash"]},
            :binary,
            :use_stdio,
            :stderr_to_stdout,
            :exit_status,
            :stream
          ])

        Logger.info("Sandbox port opened to container #{container}")
        %{state | port: port}
      rescue
        e ->
          Logger.error("Failed to open sandbox port: #{inspect(e)}")
          state
      end
    else
      Logger.error("podman executable not found")
      state
    end
  end

  defp ensure_port(state), do: state

  defp close_port(%{port: nil} = state), do: state

  defp close_port(%{port: port} = state) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    %{state | port: nil, buffer: "", mode: :idle}
  end

  defp parse_sentinel(buffer, ref) do
    start_marker = "---CMD_START_#{ref}---\n"
    end_pattern = ~r/---CMD_END_#{ref}_(\d+)---/
    cwd_pattern = ~r/---CWD_#{ref}_(.+)---/

    case :binary.match(buffer, start_marker) do
      {start_offset, start_len} ->
        output_start = start_offset + start_len
        rest = binary_part(buffer, output_start, byte_size(buffer) - output_start)

        case Regex.run(end_pattern, rest) do
          [_, exit_str] ->
            # Extract cwd from output
            new_cwd = case Regex.run(cwd_pattern, rest) do
              [_, cwd] -> String.trim(cwd)
              nil -> nil
            end

            # Remove cwd marker from visible output
            output = rest
              |> String.split(~r/\n---CMD_END_#{ref}_\d+---/, parts: 2)
              |> List.first("")
              |> String.replace(~r/\n?---CWD_#{ref}_.+---/, "")
              |> String.trim_trailing()

            {:ok, output, String.to_integer(exit_str), new_cwd}

          nil ->
            :incomplete
        end

      :nomatch ->
        :incomplete
    end
  end

  defp do_write_file(container, container_path, content) do
    tmp_dir = System.tmp_dir!()
    tmp_name = "golem_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
    tmp_path = Path.join(tmp_dir, tmp_name)

    try do
      File.write!(tmp_path, content)

      case System.cmd(Golem.Runtime.cmd(), ["cp", tmp_path, "#{container}:#{container_path}"],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {output, code} -> {:error, "podman cp failed (#{code}): #{output}"}
      end
    after
      File.rm(tmp_path)
    end
  end

  # Send the last few lines of output to the TUI for live display
  defp broadcast_output(buffer, ref) do
    lines =
      buffer
      |> String.split("\n")
      |> Enum.reject(fn line ->
        String.contains?(line, "---CMD_START_#{ref}---") or
        String.contains?(line, "---CMD_END_#{ref}") or
        String.contains?(line, "---CWD_#{ref}") or
        line == ""
      end)
      |> Enum.take(-3)

    if lines != [] do
      Golem.TUI.set_live_output(lines)
    end
  end

  defp escape(path), do: "'#{String.replace(path, "'", "'\\''")}'"

  defp default_timeout, do: Application.get_env(:golem, :command_timeout, 60_000)
  defp default_stall_timeout, do: Application.get_env(:golem, :stall_timeout, 120_000)

  defp start_stall_timer(_ref, :infinity), do: nil
  defp start_stall_timer(ref, ms) when is_integer(ms), do: Process.send_after(self(), {:stall_timeout, ref}, ms)

  defp cancel_stall_timer(nil), do: :ok
  defp cancel_stall_timer(timer), do: Process.cancel_timer(timer)
end
