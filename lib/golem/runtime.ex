defmodule Golem.Runtime do
  @moduledoc """
  Container runtime abstraction. Auto-detects podman or docker.
  """

  def cmd do
    Application.get_env(:golem, :container_runtime, "podman")
  end

  def executable do
    System.find_executable(cmd()) || cmd()
  end
end
