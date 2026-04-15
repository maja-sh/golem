defmodule Golem.Tools do
  @moduledoc """
  Tool definitions for Claude's tool use API.
  """

  @max_agent_depth 3

  @doc """
  Returns tool definitions for the given nesting depth.
  Sub-agent tool is excluded when at max depth.
  ask_user is only available when Discord is connected.
  """
  def for_depth(depth \\ 0) do
    base = base_tools()

    extras =
      (if depth < @max_agent_depth, do: [sub_agent_tool(), parallel_sub_agents_tool()], else: []) ++
        (if discord_available?(), do: [ask_user_tool()], else: [])

    base ++ extras
  end

  @doc """
  Returns all tool definitions (depth 0).
  """
  def all, do: for_depth(0)

  @doc """
  Returns read-only tools for the planner plus a create_plan tool to finalize.
  """
  def for_planner do
    [
      read_file_tool(),
      list_directory_tool(),
      glob_tool(),
      grep_tool(),
      create_plan_tool()
    ]
  end

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

  defp parallel_sub_agents_tool do
    tool("parallel_sub_agents", "Spawn multiple sub-agents to work on independent tasks concurrently. Each gets its own context. Use when you have 2-4 independent tasks that don't depend on each other — e.g. \"implement module A\" and \"write tests for module B\" at the same time. All agents share the same filesystem so avoid conflicting file writes.", %{
      type: "object",
      properties: %{
        agents: %{
          type: "array",
          description: "List of sub-agent tasks to run in parallel",
          items: %{
            type: "object",
            properties: %{
              goal: %{type: "string", description: "What this sub-agent should accomplish"},
              context: %{type: "string", description: "Context for this sub-agent"}
            },
            required: ["goal"]
          }
        }
      },
      required: ["agents"]
    })
  end

  defp ask_user_tool do
    tool("ask_user", "Ask the human operator a question via Discord and wait for their response. Use this when you face a decision that significantly affects the outcome — e.g. choosing between product ideas, picking a tech stack, or confirming a risky action. The question is sent via Discord and the run pauses until they reply. Don't use this for trivial decisions you can make yourself.", %{
      type: "object",
      properties: %{
        question: %{type: "string", description: "The question to ask. Be specific — present options if applicable, include your recommendation and reasoning."}
      },
      required: ["question"]
    })
  end

  defp read_file_tool do
    tool("read_file", "Read a file from the container. For large files, use offset and limit to read specific line ranges instead of the whole file.", %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "Absolute file path"},
        offset: %{type: "integer", description: "Start reading from this line number (1-based). Omit to start from the beginning."},
        limit: %{type: "integer", description: "Maximum number of lines to return. Omit to read the entire file. Use this for large files to avoid flooding your context."}
      },
      required: ["path"]
    })
  end

  defp list_directory_tool do
    tool("list_directory", "List the contents of a directory with file types and sizes.", %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "Absolute directory path"}
      },
      required: ["path"]
    })
  end

  defp glob_tool do
    tool("glob", "Find files matching a glob pattern. Returns matching file paths.", %{
      type: "object",
      properties: %{
        pattern: %{type: "string", description: "Glob pattern (e.g. **/*.py, src/**/*.ts, *.json)"},
        path: %{type: "string", description: "Directory to search in (default: current working directory)"}
      },
      required: ["pattern"]
    })
  end

  defp grep_tool do
    tool("grep", "Search file contents for a regex pattern. Returns matching lines with file paths and line numbers. Results are capped at 200 lines — use offset to paginate if needed.", %{
      type: "object",
      properties: %{
        pattern: %{type: "string", description: "Regex pattern to search for"},
        path: %{type: "string", description: "File or directory to search in (default: current working directory)"},
        glob: %{type: "string", description: "Only search files matching this glob (e.g. *.py)"},
        context: %{type: "integer", description: "Number of context lines before and after each match (default: 0)"},
        offset: %{type: "integer", description: "Skip this many lines of output (for paginating large result sets). Default: 0."}
      },
      required: ["pattern"]
    })
  end

  defp create_plan_tool do
    tool("create_plan", "Finalize your plan after exploring the codebase. Call this once you've read enough code to create a concrete, actionable plan. Every step that creates or modifies files MUST include a `verify:` line with a shell command that exits 0 on success (e.g. `verify: test -f /path/to/file`, `verify: cd /path && php artisan test --filter=SomeTest`). This is required — the system uses these to track progress.", %{
      type: "object",
      properties: %{
        plan: %{type: "string", description: "The full plan as a markdown checklist grouped into phases. Each step must have an indented `verify:` line with a shell command."}
      },
      required: ["plan"]
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
      read_file_tool(),
      tool("edit_file", "Make a targeted edit to a file. Finds old_string and replaces it with new_string. The old_string must match exactly (including whitespace/indentation). For creating new files, use write_file instead.", %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Absolute file path"},
          old_string: %{type: "string", description: "Exact string to find in the file"},
          new_string: %{type: "string", description: "Replacement string"}
        },
        required: ["path", "old_string", "new_string"]
      }),
      list_directory_tool(),
      glob_tool(),
      grep_tool(),
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
      tool("think", "Pause and reason about the current situation. Use this to synthesize findings, reflect on progress, or work through a complex decision. Set request_replan=true when you've gathered enough information and need the plan revised (e.g. after a research phase). Without replan, your reasoning is just captured in the conversation for context.", %{
        type: "object",
        properties: %{
          reasoning: %{type: "string", description: "Your detailed analysis — what you've learned, what's working, what isn't, what to do next"},
          request_replan: %{type: "boolean", description: "Set to true to trigger a full plan revision based on your reasoning. Use after research phases or when the current plan is fundamentally wrong. Default: false."}
        },
        required: ["reasoning"]
      }),
      tool("browse", "Open a URL in Firefox on the virtual display and take a screenshot. Returns the screenshot so you can see the page visually. Use this to verify web UIs you've built.", %{
        type: "object",
        properties: %{
          url: %{type: "string", description: "URL to open (e.g. http://localhost:3000)"}
        },
        required: ["url"]
      }),
      tool("update_progress", "Update your progress tracking. Call this as you start and complete plan steps so the operator can see your progress. Each call sets the FULL list of items — include all items every time, not just changed ones.", %{
        type: "object",
        properties: %{
          items: %{
            type: "array",
            description: "Full list of progress items",
            items: %{
              type: "object",
              properties: %{
                text: %{type: "string", description: "Short description of the step"},
                status: %{type: "string", enum: ["pending", "in_progress", "completed"], description: "Current status"}
              },
              required: ["text", "status"]
            }
          }
        },
        required: ["items"]
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

  defp discord_available? do
    System.get_env("DISCORD_TOKEN") != nil
  end

  defp tool(name, description, input_schema) do
    %{name: name, description: description, input_schema: input_schema}
  end
end
