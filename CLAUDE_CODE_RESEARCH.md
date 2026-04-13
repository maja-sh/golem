# Claude Code Architecture Research

Deep analysis of Claude Code's source (`../claude-code`) to understand what makes it effective and identify patterns applicable to Golem.

---

## 1. Sub-Agent Architecture

### Spawning & Context

Claude Code has two sub-agent models:

**Traditional Sub-Agents** (explicit `subagent_type`):
- Fresh context — only the user-provided prompt, no parent history
- Own system prompt via `agentDefinition.getSystemPrompt()`
- Isolated tool pool assembled per agent definition
- Different prompt cache prefix (cache miss vs parent)

**Fork Sub-Agents** (no `subagent_type`, implicit):
- Inherit parent's **full conversation history** — every message, every tool result
- Inherit parent's **exact system prompt** (byte-identical for cache hits)
- Inherit parent's **exact tool array** (`useExactTools: true`)
- One user message appended with placeholder tool_results + child directive
- Result: maximal prompt cache reuse across parent and all forks

Fork children cannot spawn forks (recursion guard). Detected via `querySource === 'agent:builtin:fork'` or boilerplate tag scan.

### Built-In Agent Types

| Type | Tools | Use Case |
|------|-------|----------|
| `general-purpose` | All (`['*']`) | Research, multi-step tasks |
| `Explore` | Read-only (no Edit/Write/Agent) | Codebase search, fast |
| `Plan` | Read-only | Architecture planning |
| `verification` | All | Adversarial feature verification |
| `claudeCodeGuide` | Read-only + web | Claude Code documentation |

Key insight: **Explore agents omit CLAUDE.md** from their prompt — saves ~5-15 Gtok/week across 34M+ spawns. Read-only agents don't need project instructions.

### Result Handling

Sub-agent results include structured metadata:
```
agentId, agentType, content (text), totalToolUseCount,
totalDurationMs, totalTokens, usage breakdown
```

The parent gets the last assistant message's text content. If no text found, scans backwards through all messages. This ensures the parent always gets a useful summary even if the sub-agent's final message was a tool call.

**Key difference from Golem**: Claude Code sub-agents return rich metadata (tool count, tokens, duration). Golem just returns a summary string.

### Memory System

Sub-agents have per-type persistent memory:
- `~/.claude/agent-memory/{agentType}/` — user-scoped
- `.claude/agent-memory/{agentType}/` — project-scoped
- `.claude/agent-memory-local/{agentType}/` — local-only

On spawn, a snapshot check determines whether to initialize, update, or skip memory loading.

---

## 2. Loop Prevention & Stuck Handling

### Query Loop Architecture

The main loop (`src/query.ts`) uses explicit state tracking with **transition reasons**. Every loop re-entry must declare why:

```typescript
state = { ...nextState, transition: { reason: 'token_budget_continuation' } }
continue
```

Silent re-entries are impossible. There are exactly 6 `continue` sites in the loop, each with a declared reason.

### Terminal Conditions (10+ exit paths)

| Reason | Trigger |
|--------|---------|
| `completed` | No tool_use blocks in response |
| `max_turns` | Turn counter exceeds `maxTurns` param |
| `aborted_streaming` | User interrupt during streaming |
| `aborted_tools` | Tool execution abort |
| `hook_stopped` | Stop hook prevented continuation |
| `blocking_limit` | Token count at hard blocking limit |
| `prompt_too_long` | Prompt exceeds API limits (after recovery attempts) |
| `token_budget_completion` | Token budget exhausted |
| `model_error` | Unrecoverable API error |
| `stop_hook_prevented` | Stop hooks returned blocking errors |

### What Claude Code Does NOT Have

Notably, Claude Code has **no explicit stuck detection** like Golem's file-edit loop detector or shell-repeat detector. It relies on:

1. **Prompt instructions**: "Don't retry the identical action blindly"
2. **User interaction**: The human notices and redirects
3. **maxTurns limit**: Hard cap prevents infinite loops
4. **Stop hooks**: User-defined scripts can halt the agent on custom conditions

This works because Claude Code is primarily interactive. For autonomous agents like Golem, explicit stuck detection is necessary.

### Error Recovery Chain

**Prompt-too-long** (3-tier recovery):
1. Collapse drain (cheap, preserves granular context)
2. Reactive compact (full summary)
3. Surface error to user

**Max output tokens** (counter-based):
- 3 retries with recovery messages
- After 3 failures, escalate with larger token budget
- Hard limit prevents infinite retry

**Repeated 529 (overload) errors**:
- 3 consecutive → fallback model switch
- Background tasks bail immediately (no retry)

**Key pattern**: Recovery state guards prevent re-running the same recovery twice. E.g., `hasAttemptedReactiveCompact` prevents compacting twice for the same error.

### Compilation/Build Error Handling

Claude Code has **no code-level build error detection**. It's entirely prompt-driven:

> "If an approach fails, diagnose why before switching tactics—read the error, check your assumptions, try a focused fix. Don't retry the identical action blindly."

**Golem's search-nudge approach (detecting build errors with unknown symbols and nudging `web_search`) goes beyond what Claude Code does.** This is an area where an autonomous agent needs more than what an interactive tool provides.

---

## 3. System Prompt Construction

### Architecture: Array of Sections

The system prompt is a **string array**, not a single string. Each section can have different cache behavior:

```
[intro, system, doingTasks, actions, usingTools, toneStyle, outputEfficiency,
 __DYNAMIC_BOUNDARY__,
 sessionGuidance, memory, envInfo, language, mcpInstructions, ...]
```

### Static vs Dynamic Boundary

`SYSTEM_PROMPT_DYNAMIC_BOUNDARY` separates:
- **Before** (static): Cross-org cacheable with `scope: 'global'`. Identical for all users.
- **After** (dynamic): Per-session content. Changes break cache.

This is a significant optimization — the static prefix (~5KB) is cached once and reused across millions of requests.

### Key Prompt Sections

**Intro**: Role definition, output style framing, cyber risk instruction.

**System**: Tool execution permissions, `<system-reminder>` tag handling, automatic context compression notice.

**Doing Tasks** (most important for quality):
- "Do not propose changes to code you haven't read"
- "If an approach fails, diagnose why before switching tactics"
- "Don't add features, refactor code, or make 'improvements' beyond what was asked"
- "Don't add error handling for scenarios that can't happen"
- "Don't create helpers for one-time operations"
- "Three similar lines of code is better than a premature abstraction"
- ANT-only: "Default to writing no comments" and "Before reporting complete, verify it actually works"

**Actions**: Reversibility and blast radius guidance. Confirm before destructive/shared-state actions.

**Using Your Tools**: Prefer dedicated tools (Read/Edit/Write/Glob/Grep) over Bash. Parallel tool calls when independent.

**Output Efficiency** (ANT-only):
- "Lead with the answer or action — not the reasoning that got you there"
- "Inverted pyramid: most important info first"
- "Context lives in the conversation; don't restate what's visible"

**Token Budget** (when user specifies "+500k"):
- Track cumulative output tokens via `<token-tracker>` tags
- Keep working until target reached
- Don't summarize — keep producing

### Environment Info Section

Injected per-session:
- CWD, git status, platform, shell
- Model name (marketing name, not internal ID)
- Knowledge cutoff date
- Available CLI features (desktop, web, IDE extensions)

### CLAUDE.md Loading

Priority order (highest last = wins):
1. `/etc/claude-code/CLAUDE.md` (managed/admin)
2. `~/.claude/CLAUDE.md` (user global)
3. `CLAUDE.md`, `.claude/CLAUDE.md`, `.claude/rules/*.md` (project, checked in)
4. `CLAUDE.local.md` (local, gitignored)

Features:
- **Frontmatter `paths:` globs**: Rules only apply when matching files are involved
- **`@include` directives**: `@./path/to/file` injects file content (max depth 5)
- **HTML comment stripping**: `<!-- -->` comments removed before injection
- **MEMORY.md truncation**: Line and byte caps for auto-memory files

---

## 4. Tool Result Management

### Size Limits

```
Per-tool default:          50,000 chars
Per-tool max tokens:      100,000 (~400KB)
Per-message aggregate:    200,000 chars
```

### Persist-to-Disk Strategy

When a tool result exceeds its threshold:
1. Write full content to `projectDir/sessionId/tool-results/{tool_use_id}.txt`
2. Generate preview (first 2000 bytes, truncated at newline boundary)
3. Return XML-wrapped reference to model:

```
<persisted-output>
Output too large (123 MB). Full output saved to: /path/to/file.txt

Preview (first 2 KB):
[truncated content]
</persisted-output>
```

The model can then use `Read` to access the full file if needed. This is fundamentally different from Golem's truncation (which loses the middle) — Claude Code **never loses data**, it just moves it to disk.

### Per-Message Aggregate Budget

Prevents N parallel tools from each hitting 40K and producing 400K in one turn. The `ContentReplacementState` tracks which tool results have been persisted, and decisions are frozen across resume for prompt cache consistency.

**Key insight**: Individual tools declare their own `maxResultSizeChars`. FileReadTool uses `Infinity` (self-bounds via offset/limit parameters). Bash/Grep/Glob use the 50K default.

---

## 5. Context Management (5 Layers)

Claude Code has 5 distinct context management mechanisms, from cheapest to most expensive:

### Layer 1: Tool Result Persistence (pre-entry)
Large results never enter context. Persisted to disk with preview.

### Layer 2: Microcompact (per-turn, cheap)
Two modes:
- **Cached microcompact**: Uses cache-editing API to remove old tool results without invalidating the cached prefix. Only deletes, never modifies content.
- **Time-based microcompact**: When gap since last assistant message exceeds threshold (cache is cold anyway), content-clear old tool results directly.

Compactable tools: Read, Bash, Grep, Glob, WebSearch, WebFetch, Edit, Write.

### Layer 3: Snip Compact (surgical removal)
Removes middle sections of conversation history. Keeps head (goal/plan context) and tail (recent work). Cheaper than full summary.

### Layer 4: Auto-Compact (full LLM summary)
Triggered when estimated tokens exceed threshold (~87% of context window). Uses forked agent to summarize conversation into 9-section structured summary:

1. Primary Request and Intent
2. Key Technical Concepts
3. Files and Code Sections (with snippets)
4. Errors and Fixes
5. Problem Solving
6. All User Messages (critical — preserves user intent)
7. Pending Tasks
8. Current Work (with verbatim quotes)
9. Optional Next Step

Has a **circuit breaker**: stops retrying after 3 consecutive failures.

### Layer 5: Session Memory (background extraction)
Background agent extracts key decisions/discoveries into persistent file (`~/.claude/.sessions/{id}/session-memory.md`). Survives compaction. Triggered when context > 100K tokens and growing.

### Layer 6: Context Collapse (granular archival)
Most sophisticated. Archives message groups into a collapse store with summaries. `projectView()` replays the commit log on each turn. Prevents autocompact from firing (collapse owns headroom management).

---

## 6. Compaction Summary Prompt

The compaction prompt (`src/services/compact/prompt.ts`) is notably thorough:

```
CRITICAL: Respond with TEXT ONLY. Do NOT call any tools.
Tool calls will be REJECTED and will waste your only turn.
```

Requires `<analysis>` scratchpad (stripped from final output) followed by `<summary>` with 9 sections. The analysis block improves summary quality by forcing the model to think through the conversation chronologically before summarizing.

Key anti-drift instruction:
> "Include direct quotes from the most recent conversation showing exactly what task you were working on and where you left off. This should be verbatim to ensure there's no drift in task interpretation."

Partial compact variant exists for when only recent messages need summarizing (earlier context retained).

---

## 7. Plans

- Plan files stored at `~/.claude/plans/{slug}.md` with random word slugs
- On resume: recovers plan from file, SystemFileSnapshot messages, or ExitPlanMode tool input
- On fork: copies plan to new slug (prevents parent/fork conflicts)
- Plan content injected as `PlanFileAttachment` each turn

---

## 8. Advisor System

A "stronger reviewer model" the agent can call for second opinions:

- Call before substantive work, when stuck, when changing approach, before declaring done
- Advisor sees full conversation history
- Takes ~5-10s per call
- Feature-gated, Opus 4.6+ only

---

## 9. Attachments System

Each query turn gets attachments injected as user context:

| Attachment | Purpose |
|-----------|---------|
| Git status | Current branch, staged/unstaged changes |
| File diffs | When user mentions files |
| Relevant memories | Top 5 memory files (20KB cap per turn, 60KB per session) |
| Plan file | Current plan content |
| Task list | Tracked tasks with status |
| Agent listing | Available agents for @mentions |
| Skill discovery | Skills relevant to current task |
| Deferred tools delta | New tools since last query |
| MCP instructions delta | MCP server changes |

---

## 10. Key Architectural Patterns

### Prompt Cache Optimization
- Static prefix with global cache scope
- Dynamic boundary marker
- Fork sub-agents inherit parent prompt for cache hits
- Content replacement decisions frozen across resume
- Cached microcompact uses cache-editing API (no content mutation)

### Progressive Degradation
Context pressure handled by escalating through cheaper → expensive mechanisms:
1. Tool result persistence (free — never enters context)
2. Microcompact (cheap — clear old results, keep structure)
3. Snip (medium — remove middle, keep endpoints)
4. Auto-compact (expensive — full LLM summary)
5. Session memory (background — persistent extraction)

### Explicit State Machines
- Query loop: 6 continue sites, each with declared transition reason
- Recovery chains: guards prevent re-running same recovery
- Counter-based escalation with hard limits (3 retries, then fail)

### Behavioral vs Mechanical Loop Prevention
Claude Code relies heavily on **prompt instructions** rather than code-level loop detection. This works because it's interactive (user redirects). For autonomous agents, mechanical detection (like Golem's stuck detector) is essential.

---

## 11. Gaps in Golem vs Claude Code

| Feature | Claude Code | Golem | Impact |
|---------|------------|-------|--------|
| Tool result persistence to disk | Yes (50K threshold) | No (truncate with head+tail) | High — Golem loses data |
| Per-message aggregate budget | 200K chars | None | Medium — parallel tools can flood |
| 5-layer context management | Yes | 2 layers (microcompact + LLM summary) | High — Golem compacts too often |
| Compaction summary quality | 9 sections + analysis scratchpad | 7 sections, no scratchpad | Medium |
| Sub-agent context inheritance (fork) | Full parent history | None (fresh context) | High — Golem sub-agents lack context |
| Structured sub-agent results | Tool count, tokens, duration | Summary string only | Low |
| Transition tracking in loop | Explicit reasons for every continue | Implicit recursion | Medium |
| Recovery state guards | Prevents double-recovery | None | Medium |
| Session memory (background) | Persistent extraction | None | Medium |
| Advisor (second opinion) | Stronger model review | None | Low-Medium |
| Plan recovery on resume | Multi-source fallback | Plan in saved state | Low |
| Stop hooks (external circuit breaker) | User-defined scripts | None | Low |

### Highest-Impact Improvements for Golem

1. **Tool result persistence to disk** — Don't lose data, persist and reference
2. **Sub-agent context inheritance** — Fork model gives sub-agents parent's full history
3. **Multi-layer context management** — Add snip compact between microcompact and full summary
4. **Compaction scratchpad** — Add `<analysis>` block to improve summary quality
5. **Background session memory** — Extract key decisions to persistent file
