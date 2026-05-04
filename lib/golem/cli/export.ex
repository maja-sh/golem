defmodule Golem.CLI.Export do
  @moduledoc """
  Export files from the container to local filesystem.

  Usage:

      golem export <container_path> [local_path]
  """

  def run(argv) do
    Application.ensure_all_started(:golem)
    {_opts, rest, _} = OptionParser.parse(argv, strict: [])

    case rest do
      [container_path, local_path] ->
        do_export(container_path, local_path)

      [container_path] ->
        basename = Path.basename(container_path)
        do_export(container_path, Path.join("output", basename))

      _ ->
        IO.puts(:stderr, "Usage: golem export <container_path> [local_path]")
        exit({:shutdown, 1})
    end
  end

  defp do_export(container_path, local_path) do
    IO.puts("Exporting #{container_path} → #{local_path}")
    File.mkdir_p!(local_path)

    container = Application.get_env(:golem, :container, "golem-vm")

    case System.cmd(Golem.Runtime.cmd(), ["cp", "#{container}:#{container_path}/.", local_path],
           stderr_to_stdout: true) do
      {_, 0} ->
        IO.puts("✓ Exported to #{local_path}")

      {output, code} ->
        IO.puts(:stderr, "✗ #{Golem.Runtime.cmd()} cp failed (#{code}): #{output}")
        exit({:shutdown, 1})
    end
  end
end
