defmodule Golem.Screenshot do
  @moduledoc """
  Captures screenshots from the container's virtual display.
  Saves to a local directory and returns base64-encoded image data for Claude.
  """

  require Logger

  @doc """
  Take a screenshot of the virtual display.
  Returns {:ok, %{path: local_path, base64: data}} or {:error, reason}.
  """
  def capture do
    screenshot_dir = screenshot_dir()
    File.mkdir_p!(screenshot_dir)

    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    filename = "screenshot_#{timestamp}.png"
    container_path = "/tmp/#{filename}"
    local_path = Path.join(screenshot_dir, filename)

    # Capture screenshot inside the container
    case Golem.Sandbox.exec("scrot -z #{container_path}", timeout: 10_000) do
      {:ok, %{exit_code: 0}} ->
        # Copy from container to host
        copy_to_host(container_path, local_path)

      {:ok, %{output: output}} ->
        Logger.error("scrot failed: #{output}")
        {:error, "screenshot capture failed: #{output}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp copy_to_host(container_path, local_path) do
    container = Application.get_env(:golem, :container, "golem-vm")

    case System.cmd("podman", ["cp", "#{container}:#{container_path}", local_path],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        # Read and base64 encode
        case File.read(local_path) do
          {:ok, data} ->
            base64 = Base.encode64(data)
            Logger.info("Screenshot saved: #{local_path} (#{byte_size(data)} bytes)")
            {:ok, %{path: local_path, base64: base64}}

          {:error, reason} ->
            {:error, "failed to read screenshot: #{inspect(reason)}"}
        end

      {output, code} ->
        {:error, "podman cp failed (#{code}): #{output}"}
    end
  end

  defp screenshot_dir do
    Application.get_env(:golem, :screenshot_dir, "screenshots")
  end
end
