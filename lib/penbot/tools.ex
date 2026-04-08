defmodule Penbot.Tools do
  @moduledoc """
  Tool definitions for Claude's tool use API.
  """

  @doc """
  Returns all tool definitions available to the executor.
  """
  def all do
    [
      tool("shell", "Run a shell command in the Linux container. Returns stdout/stderr and exit code.", %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "Shell command to execute"}
        },
        required: ["command"]
      }),
      tool("write_file", "Write or create a file in the container.", %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Absolute file path"},
          content: %{type: "string", description: "File contents"}
        },
        required: ["path", "content"]
      }),
      tool("read_file", "Read a file from the container.", %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Absolute file path"}
        },
        required: ["path"]
      }),
      tool("think", "Pause and reason deeply about the current situation. Use this when you're stuck, need to reconsider your approach, or face a complex decision. Your thinking will be used to revise the plan.", %{
        type: "object",
        properties: %{
          reasoning: %{type: "string", description: "Your detailed analysis of the situation, what's working, what isn't, and what to try next"}
        },
        required: ["reasoning"]
      }),
      tool("done", "Signal that the goal has been achieved or cannot be achieved.", %{
        type: "object",
        properties: %{
          success: %{type: "boolean", description: "Whether the goal was achieved"},
          summary: %{type: "string", description: "Summary of what was accomplished or why the goal couldn't be achieved"}
        },
        required: ["success", "summary"]
      })
    ]
  end

  defp tool(name, description, input_schema) do
    %{name: name, description: description, input_schema: input_schema}
  end
end
