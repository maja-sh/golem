defmodule Golem.MixProject do
  use Mix.Project

  def project do
    [
      app: :golem,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      escript: [main_module: Golem.CLI, name: "golem"]
    ]
  end

  def cli do
    [preferred_envs: ["test.e2e": :test, "escript.build": :prod]]
  end

  defp aliases do
    [
      # Run only end-to-end tests (tagged :e2e). These hit the real
      # Anthropic API so they cost money — keep them opt-in.
      "test.e2e": ["test --only e2e"]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Golem.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:dotenv, "~> 3.0", only: [:dev, :test]},
      {:yaml_elixir, "~> 2.9"},
      {:pinned_status, path: "pinned_status"}
    ]
  end
end
