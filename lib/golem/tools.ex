defmodule Golem.Tools do
  @moduledoc """
  Tool definitions for Claude's tool use API.
  """

  @doc """
  Returns tool definitions for the given nesting depth.
  Sub-agent tools are only exposed at depth 0 — nested sub-agents
  multiply orchestration overhead without parallel speedup (the
  container, filesystem, and API rate limit are all shared) and they
  freeze the parent's progress checklist while the tree resolves. If
  a sub-agent finds itself with too much work, the right answer is
  for the parent's planner to decompose better, not for the executor
  to fan out further.
  ask_user is only available when Discord is connected.
  """
  def for_depth(depth \\ 0) do
    base = base_tools()

    extras =
      (if depth == 0, do: [sub_agent_tool(), parallel_sub_agents_tool()], else: []) ++
        (if discord_available?(), do: [ask_user_tool()], else: [])

    base ++ extras ++ mcp_tools()
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
      web_search_tool(),
      web_fetch_tool(),
      create_plan_tool()
    ] ++ mcp_tools()
  end

  defp sub_agent_tool do
    tool("sub_agent", """
    Spawn a sub-agent to handle a self-contained sub-task. The sub-agent gets its own context window and works independently, then returns a summary.

    ## When to use
    - Research tasks: "Find the best library for X"
    - Self-contained implementation: "Write the test suite for module Y"
    - Exploration: "Explore this repo and summarize the architecture"
    - Wide-fan-out work that doesn't need your active reasoning

    ## When NOT to use
    - Tasks that require the main conversation's context (patterns you've been following, decisions you've made)
    - Tasks where you'd need to iterate quickly based on results — sub-agents run to completion before returning
    - Small tasks (<5 steps) — the sub-agent startup overhead isn't worth it
    - Tasks that modify files the main agent is also editing — filesystem conflicts

    ## Context matters

    Sub-agents CANNOT see your conversation history. They get only what you put in `goal` and `context`. Include:
    - File paths they should look at or modify
    - Relevant conventions and patterns from the codebase (with example files)
    - Constraints and things to avoid
    - What "done" looks like

    A vague goal like "implement the feature" will produce vague output. A specific goal like "Implement the POST /api/bulk-enroll endpoint in app/Http/Controllers/EnrollmentController.php. Follow the pattern in BulkActionController. Use the validator style from BulkCourseRequest. Tests in tests/Feature/BulkEnrollmentTest.php" produces focused work.
    """, %{
      type: "object",
      properties: %{
        goal: %{type: "string", description: "Clear, specific description of what the sub-agent should accomplish. Include file paths, patterns to follow, and what 'done' looks like."},
        context: %{type: "string", description: "All the context the sub-agent needs: file paths, example patterns to follow, decisions already made, constraints, verification commands. The sub-agent cannot see your conversation history — anything important must be in `goal` or `context`."}
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
    tool("read_file", """
    Read a file from the container.

    ## Cost awareness

    Every byte you read goes into your context and is re-sent on EVERY subsequent API call. A 500-line file read costs ~1500 tokens × 30 turns = 45K tokens by the end of the run. Read only what you need.

    ## For large files use offset/limit

    Files over ~300 lines: DO NOT read the whole thing. Use `grep` first to find the exact region, then `read_file` with `offset` and `limit` for the surrounding 30-50 lines. Example: instead of reading a 2000-line controller, grep for the method name first, then read offset=450 limit=60.

    ## For large JSON (translations, configs, lockfiles) use `jq` via shell

    Never `read_file` on translation files, `package-lock.json`, large OpenAPI specs, etc. Use jq:
    - Find keys: `jq 'keys' file.json | head -40`
    - Read one key: `jq '.common.filters.has_injury' file.json`
    - Check structure: `jq 'path(..) | join(".")' file.json | head -20`

    ## Truncation

    Results over 50KB are truncated with an explicit notice telling you the file size and how to read more. If you see `[Truncated — file has X lines...]`, use offset/limit to get more — do NOT pretend you have the full file.
    """, %{
      type: "object",
      properties: %{
        path: %{type: "string", description: "Absolute file path"},
        offset: %{type: "integer", description: "Start reading from this line number (1-based). Strongly recommended for files over 300 lines."},
        limit: %{type: "integer", description: "Maximum number of lines to return. Use 30-100 for targeted reads. Omit only for small files under 300 lines."}
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
    tool("glob", """
    Find files matching a glob pattern.

    Prefer this over `shell` with `find` or `ls` — the output is cleaner and this tool handles the common cases faster.

    Patterns:
    - `**/*.py` — all Python files recursively
    - `src/**/*.ts` — TypeScript under src/
    - `**/test_*.py` — test files
    - `*.json` — JSON files in the current directory only
    """, %{
      type: "object",
      properties: %{
        pattern: %{type: "string", description: "Glob pattern (e.g. **/*.py, src/**/*.ts, *.json)"},
        path: %{type: "string", description: "Directory to search in (default: current working directory)"}
      },
      required: ["pattern"]
    })
  end

  defp grep_tool do
    tool("grep", """
    Search file contents for a regex pattern. Returns matching lines with file paths and line numbers.

    ## Always prefer this over shell grep/rg

    - Cleaner output, structured for LLM consumption
    - Handles the 200-line cap automatically
    - No need to escape shell metacharacters

    ## Patterns are regex, not literal

    Metacharacters like `.`, `*`, `+`, `(`, `)` need escaping if you want them literal. Example: to find `array()`, search for `array\\(\\)` not `array()`.

    ## Use `context` for surrounding lines

    When searching for a symbol's definition, use `context: 5` to see 5 lines before/after each match. Much better than grepping then reading the file.

    ## Paginate large result sets

    Results are capped at 200 lines. If you need more, use `offset` to paginate. Or narrow the search with `glob` (e.g. `glob: "*.php"` to search only PHP files).
    """, %{
      type: "object",
      properties: %{
        pattern: %{type: "string", description: "Regex pattern to search for. Escape metacharacters like . * + ( ) if searching for them literally."},
        path: %{type: "string", description: "File or directory to search in (default: current working directory)"},
        glob: %{type: "string", description: "Only search files matching this glob (e.g. *.py, **/*.ts)"},
        context: %{type: "integer", description: "Number of context lines before and after each match. Use 3-10 to see surrounding code."},
        offset: %{type: "integer", description: "Skip this many lines of output (for paginating large result sets). Default: 0."}
      },
      required: ["pattern"]
    })
  end

  defp web_search_tool do
    tool("web_search", """
    Search the web for synthesized answers with source citations.

    ## When to use

    - Before using an unfamiliar library/API — your training data may be outdated
    - When you hit an error you haven't seen — search the error message verbatim
    - When working with a framework you're not 100% sure about — check current docs

    Do NOT rely on memory for API signatures, config flags, or library behavior. Search first. A 2-turn search-then-implement is far cheaper than a 10-turn trial-and-error.

    ## Good queries vs bad queries

    Good: `"Vue 3 i18n useI18n composable autoloading 2024"`, `"vite build out of memory workaround"`
    Bad: `"how to code"`, `"vue tutorial"`

    Include the version, the specific feature, and the year if recent docs matter.
    """, %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Specific search query. Include version numbers, feature names, and date qualifiers when relevant."}
      },
      required: ["query"]
    })
  end

  defp web_fetch_tool do
    tool("web_fetch", """
    Fetch the content of a URL as text. Use for reading specific docs/APIs/READMEs you've found via search.

    Large pages are truncated. Fetch specific doc pages, not top-level index pages.
    """, %{
      type: "object",
      properties: %{
        url: %{type: "string", description: "URL to fetch. Prefer specific doc/API pages over homepages."}
      },
      required: ["url"]
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
      tool("shell", """
      Run a shell command in the Linux container. Returns stdout/stderr and exit code.

      ## Command construction

      - Each call runs in a fresh bash session. PATH changes only persist if you `echo ... >> ~/.bashrc` first.
      - Chain related commands with `&&` for dependent steps, `;` for independent ones. Don't make one giant pipeline — smaller commands are easier to debug.
      - Use `cd /path && <cmd>` to run in a specific directory rather than relying on cwd.

      ## Don't rerun failed commands blindly

      If a command failed, read the error output, then:
      1. Diagnose what actually went wrong (missing dep? wrong path? permission?)
      2. Try a DIFFERENT approach — not the same command with slightly different flags
      3. Check your earlier tool results — maybe you already tried this exact thing

      Your tool_result history includes compact signatures for old calls even after cleanup (e.g. `[cleared: shell "npm run build" → exit 137, 2.3KB]`). If you see that signature, you've already tried it — don't repeat.

      ## Memory and build failures

      If a command fails with out-of-memory, exit 137/143, or stalls under memory pressure (common with `npm run build`, `webpack`, `vite build`, `tsc`):
      - Do NOT retry with a bigger `--max-old-space-size` — you may not have more RAM
      - Try lighter checks instead:
        - `tsc --noEmit` instead of a full production build
        - `vite build --minify=false` (skips terser, big memory savings)
        - `vite build --mode development` (skips optimizations)
        - `eslint <files>` + `tsc --noEmit` for TS correctness
        - `jq empty file.json` for JSON-only changes
      - For JSON/locale/doc-only changes, a full frontend build is unnecessary

      ## Long-running processes

      NEVER run long-lived processes in the foreground — they block the shell forever:
      - Dev servers: `npm run dev &` or `timeout 30 npm run dev`
      - Build watchers: always `&` + redirect output
      - Tailing logs: `timeout 10 tail -f log.txt`

      To verify a server starts: background it, sleep 2, then `curl` it.

      ## Large JSON files: use jq

      Don't `cat` large JSON files — the output floods your context. Use jq:
      - `jq 'keys' file.json` — top-level keys
      - `jq '.section.key' file.json` — specific value
      - `jq '.section.key = "value"' file.json > tmp && mv tmp file.json` — targeted edit

      ## Interactive commands

      You have NO interactive terminal. TUI apps (arrow-key menus, wizards) will hang. Use:
      - Non-interactive flags: `--yes`, `-y`, `--no-input`, `--non-interactive`
      - Pipe answers: `yes | command` or `echo "y" | command`
      - For git rebase/bisect: NEVER use `-i`. Use non-interactive alternatives.

      ## Git safety

      - NEVER use `--no-verify`, `--no-gpg-sign`, or any hook-bypassing flag unless the operator explicitly asks
      - NEVER `git push --force` or `git push -f` to a shared branch
      - NEVER `git reset --hard` without understanding what work will be lost
      - Prefer creating a new commit over `git commit --amend` unless explicitly asked
      - Check `git status` before destructive operations
      - When unsure, use `git stash` to save work before risky operations

      ## Timeouts

      Commands have a configurable timeout. If you expect a command to take >60s (installs, builds, tests), either background it or expect it may be killed. Use `timeout N <cmd>` to set a hard limit.
      """, %{
        type: "object",
        properties: %{
          command: %{type: "string", description: "Shell command to execute"}
        },
        required: ["command"]
      }),
      tool("write_file", """
      Write or create a file in the container. Overwrites if the file exists.

      ## Read before you write (CRITICAL)

      Before creating any new file:
      1. `list_directory` the target directory — see what's there
      2. `read_file` at least one similar file — learn the patterns, imports, base classes, naming
      3. `grep` for similar things in the codebase — follow existing conventions

      Do NOT guess at patterns. Read the actual code. New files that don't match the project's conventions get rewritten later, wasting steps.

      ## Verify after you write

      After every `write_file`:
      1. Syntax-check the file (`node -c`, `php -l`, `python -c 'import ast; ast.parse(open("path").read())'`)
      2. If any sibling tests exist, run the relevant one
      3. Do NOT move to the next step until the file compiles

      ## For edits to existing files, use edit_file instead

      `write_file` overwrites the entire file — any content you didn't include is lost. Use `edit_file` for targeted changes to preserve surrounding code.

      ## File size discipline

      Prefer multiple small files over one big file. >500 lines per file makes `edit_file` less reliable (exact-match harder, more places for drift). Split into modules by concern.
      """, %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Absolute file path"},
          content: %{type: "string", description: "File contents. Match the project's conventions — read similar existing files first."}
        },
        required: ["path", "content"]
      }),
      read_file_tool(),
      tool("edit_file", """
      Make a targeted edit to an existing file. Finds `old_string` and replaces it with `new_string`.

      ## Exact match required

      `old_string` must match the file EXACTLY — every space, tab, and newline. A common cause of failures is copying from a read_file output with different indentation than the actual file. When in doubt, `read_file` the target lines first to get the exact content.

      ## Read before you edit

      If you haven't read the file in this conversation (or it's been many turns), `read_file` it first. Files change — your memory of them may be stale. `edit_file` will tell you if the string is missing, but figuring out why costs extra steps.

      ## If an edit fails 3 times, stop and read

      After 3 failed edits on the same file, STOP patching:
      1. `read_file` the full relevant section
      2. Use `think` to reason about what's actually there vs what you expected
      3. Consider `write_file` to rewrite the whole file, or break it into smaller edits with more context in `old_string`

      ## Disambiguation

      If `old_string` appears multiple times in the file, the edit will fail (ambiguous). Include more surrounding context in `old_string` to make it unique — at least one line above and below, or a nearby unique identifier.

      ## New files use write_file

      `edit_file` is for existing files only. For new files, use `write_file`.
      """, %{
        type: "object",
        properties: %{
          path: %{type: "string", description: "Absolute file path"},
          old_string: %{type: "string", description: "Exact string to find. Must include enough context to be unique in the file. Copy whitespace and newlines exactly."},
          new_string: %{type: "string", description: "Replacement string. Preserve the surrounding context from old_string."}
        },
        required: ["path", "old_string", "new_string"]
      }),
      list_directory_tool(),
      glob_tool(),
      grep_tool(),
      web_search_tool(),
      web_fetch_tool(),
      tool("think", """
      Pause and reason about the current situation. Your reasoning is captured in the conversation for later reference.

      ## When to use

      - After research, before calling `create_plan` / `request_replan`: synthesize findings
      - When you're about to do something risky or expensive — reason through options first
      - When an approach keeps failing — step back and diagnose WHY

      ## When NOT to use

      - As a substitute for action. `think` does not change state. If you know what to do, use the action tool.
      - 3+ times in a row. After calling think twice in a row, the next call MUST be an action tool. The system will escalate and warn you if you keep calling think.
      - To narrate what you just did — tool results speak for themselves.

      ## request_replan

      Set `request_replan: true` only when:
      - You've finished a research phase and have concrete findings
      - The current plan is fundamentally wrong (not just a step needs tweaking)
      - You've hit a blocker that requires rethinking the approach

      Include your full findings/reasoning in the `reasoning` field — the planner will see them and build a revised plan. Don't use replan for minor adjustments; just continue or adapt the current plan.
      """, %{
        type: "object",
        properties: %{
          reasoning: %{type: "string", description: "Your detailed analysis — what you've learned, what's working, what isn't, what to do next. If request_replan=true, include enough findings for the planner to work with."},
          request_replan: %{type: "boolean", description: "Set to true to trigger a full plan revision. Use sparingly — only after research phases or when the plan is fundamentally wrong. Default: false."}
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
      tool("update_progress", """
      Update your progress tracking so the operator can see what you're working on.

      ## Call this frequently

      - At the start: seed items from the plan's checklist (all pending)
      - When starting a step: flip it to `in_progress` BEFORE the work begins
      - When finishing a step: flip it to `completed` AFTER the work is done and verified

      The operator watches this checklist — if it's stale, they don't know what you're doing.

      ## Always send the FULL list

      Every call replaces the list entirely. Include ALL items with their current status, not just changed ones. Omitting an item is equivalent to deleting it.

      ## Status meanings

      - `pending` — not started
      - `in_progress` — actively working on this right now (only ONE item should be in_progress at a time)
      - `completed` — done. The system will run your plan's `verify:` command to confirm; unverified items are displayed differently

      ## Item text

      - Keep short (under 50 chars) — items are truncated in the TUI
      - 5-15 items is the sweet spot — fewer misses context, more is noisy
      - Match the plan's phrasing where possible

      ## Progress staleness is monitored

      If you go 20+ steps without marking anything completed, the system will nudge you. Either mark progress, or use `think(request_replan: true)` if you're stuck.
      """, %{
        type: "object",
        properties: %{
          items: %{
            type: "array",
            description: "Full list of progress items. Include ALL items every call, not just changed ones.",
            items: %{
              type: "object",
              properties: %{
                text: %{type: "string", description: "Short description (under 50 chars)"},
                status: %{type: "string", enum: ["pending", "in_progress", "completed"], description: "pending | in_progress | completed"}
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
      tool("done", """
      Signal that the goal has been achieved or cannot be achieved. This ENDS the run.

      ## Before calling done(success=true)

      The run will be gated by verification. Before calling:
      1. All progress items are marked `completed`
      2. Tests pass (or you've documented why they can't)
      3. Build succeeds with no new warnings
      4. No unused imports, TODO placeholders, or commented-out code in files you changed
      5. For code changes: you've actually run the tests and seen them pass

      If verification fails, the `done` call is rejected and you get another chance. But each failed `done` costs steps, so verify first.

      ## done(success=false)

      Use when:
      - The goal is fundamentally impossible given the environment (missing deps you can't install, locked resources)
      - You've hit a hard blocker that requires human intervention
      - You've made substantial progress but cannot finish without more info

      Include a specific summary: what you accomplished, what's blocking, what the operator needs to do.

      ## Summary

      Keep to ≤100 words unless the task explicitly requires a detailed report. Focus on:
      - Files created/modified (with paths)
      - What verification you ran and its result
      - Any caveats or follow-ups
      """, %{
        type: "object",
        properties: %{
          success: %{type: "boolean", description: "Whether the goal was achieved. Only true if you've verified the work."},
          summary: %{type: "string", description: "Concise summary (≤100 words): files changed, verification run, caveats. Not a narrative of what you did."}
        },
        required: ["success", "summary"]
      })
    ]
  end

  defp discord_available? do
    System.get_env("DISCORD_TOKEN") != nil
  end

  defp mcp_tools do
    Golem.MCP.tools()
  end

  defp tool(name, description, input_schema) do
    %{name: name, description: description, input_schema: input_schema}
  end
end
