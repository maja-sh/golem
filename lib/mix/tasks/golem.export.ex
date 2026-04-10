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
    Mix.shell().info("Exporting #{container_path} → #{local_path}")
    File.mkdir_p!(local_path)

    container = Application.get_env(:golem, :container, "golem-vm")

    case System.cmd(Golem.Runtime.cmd(), ["cp", "#{container}:#{container_path}/.", local_path],
           stderr_to_stdout: true) do
      {_, 0} ->
        Mix.shell().info("✓ Exported to #{local_path}")

      {output, code} ->
        Mix.shell().error("✗ podman cp failed (#{code}): #{output}")
    end
  end
end
