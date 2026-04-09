# TODO

## Jira/Bitbucket Integration

Dispatch Golem to work on Jira tickets autonomously.

### Flow
1. `mix golem.jira PROJ-123` (or Discord command)
2. Read ticket via Jira API → quality gate (score 1-5, refuse if too vague)
3. Clone repo (if not cached) → git worktree for this ticket
4. Read AGENTS.md → inject into system prompt
5. Create branch `golem/PROJ-123`
6. Run setup from README
7. Work on ticket (existing runner loop with per-ticket cost cap)
8. Run tests
9. git push → create draft PR on Bitbucket (assign repo owner as reviewer)
10. Discord: "PR ready for PROJ-123 — link"
11. Clean up worktree

### Multi-ticket in one container
Use git worktrees — one repo clone, multiple working directories:
```
/home/agent/repos/myproject/          ← main clone (shared .git)
/home/agent/worktrees/PROJ-123/      ← worktree for ticket 123
/home/agent/worktrees/PROJ-456/      ← worktree for ticket 456
```
Shared build cache, no re-cloning, no extra containers.

### Safety
- Per-ticket cost cap (default $20) — pause + Discord notify
- Error rate circuit breaker: >50% errors in last 10 steps → pause
- Idle detection: no progress in 20 steps → pause
- Ticket quality gate: refuse vague tickets, ask clarifying questions

### Needs
- Jira base URL + API token
- Bitbucket app password or token (for git push + PR creation)
- Custom tools: `jira_read_ticket`, `jira_comment`, `jira_transition`, `bitbucket_create_pr`
- Mix task: `mix golem.jira PROJ-123`
- Git worktree management in Sandbox

### AGENTS.md
Already implemented — `agents_md` option passed to runner, injected into system prompt. Jira flow reads it from repo root after cloning.
