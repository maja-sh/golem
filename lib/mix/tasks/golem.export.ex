defmodule Mix.Tasks.Golem.Export do
  @moduledoc """
  Export files from the container to local filesystem.

  ## Usage

      mix golem.export /home/agent/product ./output/product
      mix golem.export /home/agent/product
  """

  use Mix.Task

  @shortdoc "Export files from the container"

  @impl true
  def run(args) do
    {_opts, rest, _} = OptionParser.parse(args, strict: [])

    case rest do
      [container_path, local_path] ->
        do_export(container_path, local_path)

      [container_path] ->
        # Default to output/<basename>
        basename = Path.basename(container_path)
        do_export(container_path, Path.join("output", basename))

      _ ->
        Mix.shell().error("Usage: mix golem.export <container_path> [local_path]")
        exit({:shutdown, 1})
    end
  end

  defp do_export(container_path, local_path) do
    Mix.Task.run("app.start")
    Mix.shell().info("Exporting #{container_path} → #{local_path}")

    case Golem.export(container_path, local_path) do
      {:ok, path} ->
        Mix.shell().info("✓ Exported to #{path}")

      {:error, reason} ->
        Mix.shell().error("✗ #{reason}")
    end
  end
end
