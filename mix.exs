defmodule Penbot.MixProject do
  use Mix.Project

  def project do
    [
      app: :penbot,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Penbot.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:dotenv, "~> 3.0", only: [:dev, :test]},
      {:nostrum, "~> 0.10", runtime: false}
    ]
  end
end
