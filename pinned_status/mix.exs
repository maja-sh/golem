defmodule PinnedStatus.MixProject do
  use Mix.Project

  def project do
    [
      app: :pinned_status,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      # Scenario .exs files are data, not test modules — they're
      # loaded explicitly by Scenario.load/1.
      test_ignore_filters: [&String.starts_with?(&1, "test/scenarios/")]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps, do: []

  defp description do
    "A pinned status block at the bottom of the terminal, with diff-based " <>
      "redraws so unchanged lines emit zero bytes (no flicker)."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{}
    ]
  end
end
