defmodule Penbot.Application do
  use Application

  @impl true
  def start(_type, _args) do
    setup_file_logger()

    token = System.get_env("DISCORD_TOKEN")

    if token do
      Application.put_env(:nostrum, :token, token)
    end

    children = [
      Penbot.Sandbox,
      Penbot.FileCache
    ]

    opts = [strategy: :one_for_one, name: Penbot.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Start Discord if token is available
    if token do
      Penbot.Discord.init_waiter()
      Application.ensure_all_started(:nostrum)
      Supervisor.start_child(Penbot.Supervisor, Penbot.Discord)
    end

    {:ok, pid}
  end

  defp setup_file_logger do
    log_dir = Application.get_env(:penbot, :log_dir, "logs")
    File.mkdir_p!(log_dir)
    log_file = Path.join(log_dir, "penbot.log") |> String.to_charlist()

    :logger.add_handler(:penbot_file, :logger_std_h, %{
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
