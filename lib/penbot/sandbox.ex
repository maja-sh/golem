defmodule Penbot.Sandbox do
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
  """
  def exec(command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, default_timeout())
    GenServer.call(__MODULE__, {:exec, command, timeout}, timeout + 5_000)
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
    # Use exec to cat the file — simpler than podman cp out
    case exec("cat #{escape(container_path)}", timeout: 10_000) do
      {:ok, %{exit_code: 0, output: content}} -> {:ok, content}
      {:ok, %{output: err}} -> {:error, err}
      error -> error
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
    container = Application.get_env(:penbot, :container, "penbot-vm")
    Logger.info("Sandbox initialized, container: #{container}")
    {:ok, %{port: nil, container: container, buffer: "", mode: :idle}}
  end

  @impl true
  def handle_call({:exec, command, timeout}, from, %{mode: :idle} = state) do
    state = ensure_port(state)

    case state.port do
      nil ->
        {:reply, {:error, :port_not_available}, state}

      port ->
        ref = :crypto.strong_rand_bytes(8) |> Base.encode16()

        wrapped =
          "echo '---CMD_START_#{ref}---'; (#{command}) 2>&1; __exit=$?; echo ''; echo \"---CMD_END_#{ref}_${__exit}---\"\n"

        Port.command(port, wrapped)
        timer = Process.send_after(self(), {:exec_timeout, ref}, timeout)
        {:noreply, %{state | buffer: "", mode: {:exec, ref, from, timer}}}
    end
  end

  def handle_call({:exec, _command, _timeout}, _from, state) do
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
    System.cmd("podman", ["stop", "-t", "2", container], stderr_to_stdout: true)
    System.cmd("podman", ["rm", "-f", container], stderr_to_stdout: true)

    # Recreate from image
    case System.cmd("podman", [
           "run", "-d",
           "--name", container,
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
    case System.cmd("podman", ["inspect", "-f", "{{.State.Status}}", state.container],
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
      {:exec, ref, from, timer} ->
        case parse_sentinel(buffer, ref) do
          {:ok, output, exit_code} ->
            Process.cancel_timer(timer)
            GenServer.reply(from, {:ok, %{output: output, exit_code: exit_code}})
            {:noreply, %{state | buffer: "", mode: :idle}}

          :incomplete ->
            {:noreply, %{state | buffer: buffer}}
        end

      :idle ->
        {:noreply, %{state | buffer: ""}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Sandbox port exited with status #{status}")

    case state.mode do
      {:exec, _ref, from, timer} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:error, :port_died})

      :idle ->
        :ok
    end

    {:noreply, %{state | port: nil, buffer: "", mode: :idle}}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    if state.port != nil and pid == state.port do
      Logger.warning("Sandbox port process exited: #{inspect(reason)}")

      case state.mode do
        {:exec, _ref, from, timer} ->
          Process.cancel_timer(timer)
          GenServer.reply(from, {:error, :port_died})

        :idle ->
          :ok
      end

      {:noreply, %{state | port: nil, buffer: "", mode: :idle}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:exec_timeout, ref}, state) do
    case state.mode do
      {:exec, ^ref, from, _timer} ->
        Logger.warning("Sandbox exec timed out, partial output: #{byte_size(state.buffer)} bytes")
        # Return partial output on timeout instead of just an error
        GenServer.reply(from, {:error, {:timeout, state.buffer}})
        {:noreply, %{state | buffer: "", mode: :idle}}

      _ ->
        {:noreply, state}
    end
  end

  # --- Private ---

  defp ensure_port(%{port: nil, container: container} = state) do
    podman = System.find_executable("podman")

    if podman do
      try do
        port =
          Port.open({:spawn_executable, podman}, [
            {:args, ["exec", "-i", "-u", "root", container, "/bin/bash"]},
            :binary,
            :use_stdio,
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

    case :binary.match(buffer, start_marker) do
      {start_offset, start_len} ->
        output_start = start_offset + start_len
        rest = binary_part(buffer, output_start, byte_size(buffer) - output_start)

        case Regex.run(end_pattern, rest) do
          [_, exit_str] ->
            [output | _] = String.split(rest, ~r/\n---CMD_END_#{ref}_\d+---/, parts: 2)
            {:ok, String.trim_trailing(output), String.to_integer(exit_str)}

          nil ->
            :incomplete
        end

      :nomatch ->
        :incomplete
    end
  end

  defp do_write_file(container, container_path, content) do
    tmp_dir = System.tmp_dir!()
    tmp_name = "penbot_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
    tmp_path = Path.join(tmp_dir, tmp_name)

    try do
      File.write!(tmp_path, content)

      case System.cmd("podman", ["cp", tmp_path, "#{container}:#{container_path}"],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {output, code} -> {:error, "podman cp failed (#{code}): #{output}"}
      end
    after
      File.rm(tmp_path)
    end
  end

  defp escape(path), do: "'#{String.replace(path, "'", "'\\''")}'"

  defp default_timeout, do: Application.get_env(:penbot, :command_timeout, 60_000)
end
