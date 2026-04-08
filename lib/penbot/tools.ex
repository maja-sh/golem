defmodule Penbot.Tools do
  @moduledoc """
  Tool definitions for Claude's tool use API.
  """

  @max_agent_depth 3

  @doc """
  Returns tool definitions for the given nesting depth.
  Sub-agent tool is excluded when at max depth.
  """
  def for_depth(depth \\ 0) do
    base = base_tools()

    if depth < @max_agent_depth do
      base ++ [sub_agent_tool()]
    else
      base
    end
  end

  @doc """
  Returns all tool definitions (depth 0).
  """
  def all, do: for_depth(0)

  defp sub_agent_tool do
    tool("sub_agent", "Spawn a sub-agent to handle a self-contained sub-task. The sub-agent gets its own context window and works independently, then returns a summary. Use this for tasks that are complex enough to need many steps but don't need your full context — e.g. \"research how to set up nginx reverse proxy\", \"write the test suite for module X\", \"explore this directory and summarize the codebase\".", %{
      type: "object",
      properties: %{
        goal: %{type: "string", description: "Clear description of what the sub-agent should accomplish"},
        context: %{type: "string", description: "Any relevant context the sub-agent needs (file paths, decisions made so far, constraints)"}
      },
      required: ["goal"]
    })
  end

  defp base_tools do
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
      tool("edit_file", "Make a targeted edit to a file. Finds old_string and replaces it with new_string. The old_string must match exactly (including whitespace/indentation). For creating new files, use write_file instead.", %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Absolute file path"},
          old_string: %{type: "string", description: "Exact string to find in the file"},
          new_string: %{type: "string", description: "Replacement string"}
        },
        required: ["path", "old_string", "new_string"]
      }),
      tool("list_directory", "List the contents of a directory with file types and sizes.", %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Absolute directory path"}
        },
        required: ["path"]
      }),
      tool("glob", "Find files matching a glob pattern. Returns matching file paths.", %{
        type: "object",
        properties: %{
          pattern: %{type: "string", description: "Glob pattern (e.g. **/*.py, src/**/*.ts, *.json)"},
          path: %{type: "string", description: "Directory to search in (default: current working directory)"}
        },
        required: ["pattern"]
      }),
      tool("grep", "Search file contents for a regex pattern. Returns matching lines with file paths and line numbers.", %{
        type: "object",
        properties: %{
          pattern: %{type: "string", description: "Regex pattern to search for"},
          path: %{type: "string", description: "File or directory to search in (default: current working directory)"},
          glob: %{type: "string", description: "Only search files matching this glob (e.g. *.py)"},
          context: %{type: "integer", description: "Number of context lines before and after each match (default: 0)"}
        },
        required: ["pattern"]
      }),
      tool("web_search", "Search the web for information. Returns synthesized answers with source citations.", %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Search query"}
        },
        required: ["query"]
      }),
      tool("web_fetch", "Fetch the content of a URL and return it as text. Useful for reading documentation, APIs, READMEs.", %{
        type: "object",
        properties: %{
          url: %{type: "string", description: "URL to fetch"}
        },
        required: ["url"]
      }),
      tool("think", "Pause and reason deeply about the current situation. Use this when you're stuck, need to reconsider your approach, or face a complex decision. Your thinking will be used to revise the plan.", %{
        type: "object",
        properties: %{
          reasoning: %{type: "string", description: "Your detailed analysis of the situation, what's working, what isn't, and what to try next"}
        },
        required: ["reasoning"]
      }),
      tool("screenshot", "Take a screenshot of the virtual display to see GUI applications visually.", %{
        type: "object",
        properties: %{},
        required: []
      }),
      tool("gui_click", "Click at a position on the virtual display.", %{
        type: "object",
        properties: %{
          x: %{type: "integer", description: "X coordinate"},
          y: %{type: "integer", description: "Y coordinate"}
        },
        required: ["x", "y"]
      }),
      tool("gui_type", "Type text into the focused GUI application.", %{
        type: "object",
        properties: %{
          text: %{type: "string", description: "Text to type"}
        },
        required: ["text"]
      }),
      tool("gui_key", "Press a key or key combination in the GUI (xdotool format, e.g. Return, ctrl+l, Escape, Tab).", %{
        type: "object",
        properties: %{
          key: %{type: "string", description: "Key name or combo"}
        },
        required: ["key"]
      }),
      tool("gui_scroll", "Scroll up or down in the focused GUI window.", %{
        type: "object",
        properties: %{
          direction: %{type: "string", enum: ["up", "down"]},
          clicks: %{type: "integer", description: "Number of scroll clicks (default 3)"}
        },
        required: ["direction"]
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
