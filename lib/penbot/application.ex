defmodule Penbot.Application do
  use Application

  @impl true
  def start(_type, _args) do
    setup_file_logger()

    children = [
      Penbot.Sandbox
    ]

    opts = [strategy: :one_for_one, name: Penbot.Supervisor]
    Supervisor.start_link(children, opts)
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
