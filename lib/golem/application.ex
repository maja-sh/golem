defmodule Golem.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Load user config from .golem/config.yaml and GOLEM_* env vars first.
    # ensure_defaults/0 only fills in keys that are still unset, so anything
    # the user configured takes precedence over the hard-coded fallbacks.
    Golem.Config.load()
    ensure_defaults()
    setup_file_logger()

    unless Application.get_env(:golem, :output_backend) do
      Application.put_env(:golem, :output_backend, Golem.TUI)
    end

    # Console handler level: silent under the TUI (the file handler still
    # captures everything to logs/golem.log), info elsewhere. The TUI also
    # re-asserts :none at init_display time as a belt-and-braces guard.
    console_level =
      if Application.get_env(:golem, :output_backend) == Golem.TUI,
        do: :none,
        else: :info

    for id <- :logger.get_handler_ids(), id != :golem_file do
      :logger.set_handler_config(id, :level, console_level)
    end

    children = [
      Golem.Sandbox,
      Golem.FileCache,
      # Golem.TUI lazy-starts PinnedStatus inside init_display so the
      # cursor isn't hidden for non-TUI mix tasks like `mix golem.config`.
      Golem.TUI,
      Golem.MCP
    ]

    opts = [strategy: :one_for_one, name: Golem.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp ensure_defaults do
    defaults = [
      container: "golem-vm",
      container_image: "localhost/golem-vm:latest",
      container_user: "agent",
      planner_model: "claude-opus-4-7",
      planner_provider: :anthropic,
      executor_model: "claude-sonnet-4-6",
      executor_provider: :anthropic,
      compaction_provider: :anthropic,
      planner_max_tokens: 16_000,
      planner_max_steps: 75,
      executor_max_tokens: 16_000,
      # Total prompt budget per model call. 200_000 is the standard
      # context for Sonnet 4.6 / Opus 4.7. Setting this above 200_000
      # automatically enables Anthropic's 1M-context beta and incurs
      # 2× input pricing on tokens above the 200K mark.
      context_window: 200_000,
      # Whether to post status comments on the Jira ticket — accept/reject
      # evaluation, success, failure, paused, and error outcomes. Set to
      # false in `.golem/config.yaml` (`jira.comment_on_ticket: false`)
      # to keep the ticket history clean and have Golem operate silently.
      jira_comment_on_ticket: true,
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
