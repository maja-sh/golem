defmodule Penbot.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Penbot.Sandbox
    ]

    opts = [strategy: :one_for_one, name: Penbot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
