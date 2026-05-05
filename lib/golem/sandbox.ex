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
    do_exec(command, timeout, stall_timeout, _attempt = 0)
  end

  # The Sandbox GenServer serializes commands — only one can run at a
  # time. Rather than exposing `:busy` to callers (the old behavior
  # caused retry loops when several tool calls fired concurrently),
  # wait-and-retry inside the client so concurrent callers queue
  # naturally. Total wait is capped so genuine deadlocks still surface.
  @busy_max_wait_ms 30_000
  @busy_base_backoff_ms 50

  defp do_exec(command, timeout, stall_timeout, attempt) do
    case GenServer.call(__MODULE__, {:exec, command, timeout, stall_timeout}, timeout + 5_000) do
      {:error, :busy} ->
        waited = busy_total_wait(attempt)

        if waited >= @busy_max_wait_ms do
          {:error, :busy}
        else
          Process.sleep(busy_backoff(attempt))
          do_exec(command, timeout, stall_timeout, attempt + 1)
        end

      other ->
        other
    end
  catch
    :exit, _ -> {:error, :timeout}
  end

  # Linear-ish backoff capped at 500ms per wait. Cumulative limit is
  # enforced by busy_total_wait/1.
  defp busy_backoff(attempt), do: min(@busy_base_backoff_ms * (attempt + 1), 500)

  defp busy_total_wait(attempt) do
    0..attempt
    |> Enum.map(&busy_backoff/1)
    |> Enum.sum()
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
    image = Application.get_env(:golem, :container_image, "golem-vm:latest")
    Logger.debug("Sandbox initialized, container: #{container}")

    # Auto-provision the container on boot so the user never has to
    # run `./containers/start.sh` manually. No-op if it's already
    # running. Creates from the image if missing, starts if stopped.
    case ensure_container(container, image) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Container auto-provision failed: #{reason}. Run ./containers/start.sh manually.")
    end

    {:ok, %{port: nil, container: container, buffer: "", mode: :idle, cwd: nil, stall_ms: nil}}
  end

  # --- Auto-provisioning ---
  #
  # Replicates the essential parts of containers/start.sh so the user
  # doesn't need to run it manually. Idempotent. Mounts and env vars
  # come from .golem/config.yml — nothing about SSH, gcloud, or other
  # secrets is hardcoded in this file.
  defp ensure_container(name, image) do
    runtime = Golem.Runtime.cmd()

    case System.find_executable(runtime) do
      nil ->
        {:error, "#{runtime} not found in PATH"}

      exe ->
        case container_state(exe, name) do
          :running ->
            :ok

          :stopped ->
            Logger.info("Starting existing container #{name}")
            case System.cmd(exe, ["start", name], stderr_to_stdout: true) do
              {_, 0} -> :ok
              {out, _} -> {:error, "failed to start #{name}: #{String.trim(out)}"}
            end

          :missing ->
            Logger.info("Container #{name} not found — creating from #{image}")
            create_container(exe, name, image)
        end
    end
  end

  defp container_state(exe, name) do
    case System.cmd(exe, ["inspect", "-f", "{{.State.Status}}", name], stderr_to_stdout: true) do
      {output, 0} ->
        case String.trim(output) do
          "running" -> :running
          _ -> :stopped
        end

      {_, _} ->
        :missing
    end
  end

  defp create_container(exe, name, image) do
    with :ok <- ensure_image(exe, image) do
      args = ["run", "-d", "--name", name, "--privileged", "-v", "golem-data:/home/agent"]
      args = args ++ build_mount_args()
      args = args ++ build_env_args()
      args = args ++ [image]

      case System.cmd(exe, args, stderr_to_stdout: true) do
        {_, 0} ->
          Logger.info("Container #{name} created")
          :ok

        {out, _} ->
          {:error, "failed to create #{name}: #{String.trim(out)}"}
      end
    end
  end

  # Ensure the container image exists locally. If missing, build it
  # from the Dockerfile + entrypoint embedded at compile time via
  # Golem.Container.Assets, so the escript binary is self-contained.
  # First-run build is slow (~5-10 min); subsequent calls are instant.
  # User sees a header + spinner + elapsed timer; raw podman output is
  # captured silently and only dumped on failure.
  defp ensure_image(exe, image) do
    case System.cmd(exe, ["image", "exists", image], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {_, _} ->
        build_dir = Path.join(System.tmp_dir!(), "golem-build-#{:rand.uniform(99_999_999)}")

        try do
          Golem.Container.Assets.write_to(build_dir)
          dockerfile = Path.join(build_dir, "Dockerfile")
          run_image_build(exe, image, dockerfile, build_dir)
        after
          File.rm_rf!(build_dir)
        end
    end
  end

  defp run_image_build(exe, image, dockerfile, build_dir) do
    IO.puts(
      IO.ANSI.format([
        "  ",
        :bright,
        "Building #{image}",
        :reset,
        :faint,
        " (first run — ~5-10 minutes)",
        :reset
      ])
    )

    start = System.monotonic_time(:millisecond)
    spinner = Task.async(fn -> spinner_loop(start, 0) end)

    {output, exit_code} =
      System.cmd(exe, ["build", "-t", image, "-f", dockerfile, build_dir],
        stderr_to_stdout: true
      )

    send(spinner.pid, :stop)
    Task.await(spinner, 2_000)
    IO.write("\r\e[2K")

    elapsed = System.monotonic_time(:millisecond) - start

    case exit_code do
      0 ->
        IO.puts(
          IO.ANSI.format([
            "  ",
            :green,
            "✓ ",
            :reset,
            "image built in ",
            :bright,
            format_elapsed(elapsed),
            :reset
          ])
        )

        Logger.info("Image #{image} built successfully in #{format_elapsed(elapsed)}")
        :ok

      code ->
        IO.puts(
          IO.ANSI.format([
            "  ",
            :red,
            "✗ ",
            :reset,
            "build failed (exit #{code})"
          ])
        )

        IO.puts(IO.ANSI.format([:faint, output, :reset]))
        Logger.error("Image #{image} build failed: exit #{code}")
        {:error, "failed to build image #{image}. See output above."}
    end
  end

  @spinner_frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  defp spinner_loop(start, idx) do
    receive do
      :stop -> :ok
    after
      120 ->
        frame = Enum.at(@spinner_frames, rem(idx, length(@spinner_frames)))
        elapsed = System.monotonic_time(:millisecond) - start

        IO.write(
          IO.ANSI.format([
            "\r\e[2K  ",
            :cyan,
            frame,
            :reset,
            " building ",
            :faint,
            format_elapsed(elapsed),
            :reset
          ])
        )

        spinner_loop(start, idx + 1)
    end
  end

  defp format_elapsed(ms) do
    total = div(ms, 1000)
    minutes = div(total, 60)
    seconds = rem(total, 60)
    "#{minutes}:#{String.pad_leading(to_string(seconds), 2, "0")}"
  end

  # Build `-v host:container[:ro]` args from the `container.mounts`
  # list in .golem/config.yml. Missing `src` paths are silently
  # skipped unless the entry has `required: true`.
  defp build_mount_args do
    mounts = Golem.Config.raw_yaml() |> get_in(["container", "mounts"]) || []

    Enum.flat_map(mounts, fn entry ->
      src = Golem.Config.expand_path(Map.get(entry, "src") || "")
      dest = Map.get(entry, "dest") || ""
      readonly = Map.get(entry, "readonly", false)
      required = Map.get(entry, "required", false)

      cond do
        src == "" or dest == "" ->
          Logger.warning("container.mounts entry missing src/dest: #{inspect(entry)}")
          []

        not path_exists?(src) ->
          if required,
            do: raise("required mount source not found: #{src}"),
            else: []

        true ->
          spec = "#{Path.expand(src)}:#{dest}" <> if(readonly, do: ":ro", else: "")
          ["-v", spec]
      end
    end)
  end

  # Build `-e NAME=VALUE` args from `container.env`. Accepts two forms:
  #
  #   - "GIT_USER"                          (pass through from host env if set)
  #   - %{"name" => _, "value" => _,        (static value)
  #       "when_file" => optional}          (only set if host file exists)
  defp build_env_args do
    entries = Golem.Config.raw_yaml() |> get_in(["container", "env"]) || []

    Enum.flat_map(entries, fn
      name when is_binary(name) ->
        case System.get_env(name) do
          nil -> []
          "" -> []
          value -> ["-e", "#{name}=#{value}"]
        end

      %{"name" => name, "value" => value} = entry ->
        gate = Map.get(entry, "when_file")
        gate_path = if gate, do: Golem.Config.expand_path(gate), else: nil

        if gate_path == nil or File.exists?(gate_path) do
          ["-e", "#{name}=#{value}"]
        else
          []
        end

      other ->
        Logger.warning("container.env entry not recognized: #{inspect(other)}")
        []
    end)
  end

  defp path_exists?(path), do: File.exists?(path) or File.dir?(path)

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
        case parse_sentinel(buffer, ref) do
          {:ok, output, exit_code, new_cwd} ->
            Process.cancel_timer(timer)
            cancel_stall_timer(stall_timer)
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

  defp escape(path), do: "'#{String.replace(path, "'", "'\\''")}'"

  defp default_timeout, do: Application.get_env(:golem, :command_timeout, 60_000)
  defp default_stall_timeout, do: Application.get_env(:golem, :stall_timeout, 120_000)

  defp start_stall_timer(_ref, :infinity), do: nil
  defp start_stall_timer(ref, ms) when is_integer(ms), do: Process.send_after(self(), {:stall_timeout, ref}, ms)

  defp cancel_stall_timer(nil), do: :ok
  defp cancel_stall_timer(timer), do: Process.cancel_timer(timer)
end
