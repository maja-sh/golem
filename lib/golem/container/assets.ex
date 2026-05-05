defmodule Golem.Container.Assets do
  @moduledoc false

  # Embed the container build assets at compile time so the escript
  # binary is self-contained — `golem run` can build the image without
  # needing the source repo on disk.

  @container_dir Path.expand("../../../containers", __DIR__)

  @dockerfile_path Path.join(@container_dir, "Dockerfile")
  @entrypoint_path Path.join(@container_dir, "entrypoint.sh")

  @external_resource @dockerfile_path
  @external_resource @entrypoint_path

  @files [
    {"Dockerfile", File.read!(@dockerfile_path), 0o644},
    {"entrypoint.sh", File.read!(@entrypoint_path), 0o755}
  ]

  @doc """
  Returns `[{filename, contents, mode}]` for every file the Dockerfile
  needs in its build context.
  """
  def files, do: @files

  @doc """
  Write all bundled assets into `dir`, creating it if needed. Sets
  executable bit on shell scripts so `COPY` preserves +x in the image.
  """
  def write_to(dir) do
    File.mkdir_p!(dir)

    for {name, contents, mode} <- @files do
      path = Path.join(dir, name)
      File.write!(path, contents)
      File.chmod!(path, mode)
    end

    :ok
  end
end
