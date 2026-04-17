defmodule Golem.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Load user config from .golem/config.yml and GOLEM_* env vars first.
    # ensure_defaults/0 only fills in keys that are still unset, so anything
    # the user configured takes precedence over the hard-coded fallbacks.
    Golem.Config.load()
    ensure_defaults()
    setup_file_logger()

    # Set console handler to info level — debug goes to file only
    for id <- :logger.get_handler_ids(), id != :golem_file do
      :logger.set_handler_config(id, :level, :info)
    end

    # Set output backend — daemon mode uses Discord, CLI uses TUI
    unless Application.get_env(:golem, :output_backend) do
      Application.put_env(:golem, :output_backend, Golem.TUI)
    end

    token = System.get_env("DISCORD_TOKEN")

    if token do
      Application.put_env(:nostrum, :token, token)
    end

    children = [
      Golem.Sandbox,
      Golem.FileCache,
      Golem.TUI,
      Golem.MCP,
      Golem.DaemonRunner
    ]

    opts = [strategy: :one_for_one, name: Golem.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Start Discord if token is available
    if token do
      Golem.Discord.init_waiter()
      Application.ensure_all_started(:nostrum)
      Supervisor.start_child(Golem.Supervisor, Golem.Discord)
    end

    {:ok, pid}
  end

  defp ensure_defaults do
    defaults = [
      container: "golem-vm",
      container_user: "agent",
      planner_model: "claude-opus-4-7",
      executor_model: "claude-opus-4-7",
      planner_max_tokens: 16_000,
      planner_max_steps: 75,
      executor_max_tokens: 16_000,
      # Extended thinking. With Opus 4.7 and later, thinking.type: "adaptive"
      # breaks prompt caching — every call creates a fresh cache entry, wiping
      # out the ~90% input savings. Leave disabled unless a specific run needs
      # the reasoning boost more than the cache hits.
      thinking_budget: nil,
      max_steps: 200,
      max_cost: 10.0,
      command_timeout: 900_000,
      stall_timeout: 120_000,
      container_runtime: detect_runtime(),
      screenshot_dir: "screenshots",
      log_dir: "logs"
    ]

    for {key, default} <- defaults do
      unless Application.get_env(:golem, key) do
        Application.put_env(:golem, key, default)
      end
    end

    # Suppress Nostrum warnings
    Application.put_env(:nostrum, :youtubedl, nil)
    Application.put_env(:nostrum, :streamlink, nil)
  end

  defp detect_runtime do
    cond do
      System.find_executable("podman") -> "podman"
      System.find_executable("docker") -> "docker"
      true -> "podman"
    end
  end

  defp setup_file_logger do
    log_dir = Application.get_env(:golem, :log_dir, "logs")
    File.mkdir_p!(log_dir)
    log_file = Path.join(log_dir, "golem.log") |> String.to_charlist()

    :logger.add_handler(:golem_file, :logger_std_h, %{
      config: %{
        file: log_file,
        max_no_bytes: :infinity,
        max_no_files: 1
      },
      formatter:
        {:logger_formatter,
         %{
           template: [:time, " [", :level, "] ", :msg, "\n"],
           single_line: false
         }},
      level: :debug
    })
  end
end
