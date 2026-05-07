# Build Something Developers Would Share

**Difficulty:** Very Hard (creative + full build)
**Expected steps:** 150-300
**Recommended max_steps:** 400
**Tools exercised:** web_search, web_fetch, think, write_file, edit_file, shell, sub_agent, glob, grep, browse

## Goal

Build a small, opinionated, genuinely creative software product that a developer would see on Hacker News and think "holy shit, I need that." Not a boring SaaS. Not a CRUD app. Something with personality.

### Environment

You have root access to a Ubuntu 24.04 container with Python, Node.js, and basic Linux tools. Elixir and PHP are NOT pre-installed — install what you need. Firefox is available on DISPLAY=:99 for testing web UIs.

### What makes a good product

Think about tools that developers actually get excited about and share:
- **htop** — made `top` fun to look at
- **jq** — one thing, done perfectly, impossible to live without after trying it
- **bat** — `cat` with wings, nobody asked for it, everybody loves it
- **ngrok** — "holy shit I can expose localhost?" moment
- **fig/warp** — reimagined the terminal
- **carbon.now.sh** — turn code into pretty screenshots, weirdly useful

The pattern: take something developers already do and make it **10x more fun, visual, or delightful**. Not more features — more personality.

### What NOT to build

- Anything that exists as a category (invoicing, CRM, monitoring, time tracking, forms, etc.)
- Anything described as "X but for Y" where X already works fine
- Anything that requires a sales team or enterprise pitch to sell
- Anything boring. If you wouldn't tweet about it, don't build it.

### Categories to explore (pick ONE or invent your own)

- **CLI tools that make ugly things beautiful** — git log, docker ps, server logs, test output, database queries, API responses
- **Dev workflow tools that feel like magic** — one command that does something you'd normally spend 5 minutes doing manually
- **Visual/creative dev tools** — things that turn code/data into something visual, shareable, or just fun to look at
- **Niche power tools** — something that 1000 developers would pay $10/month for because it saves them 30 minutes a day on a specific annoying task
- **Developer entertainment** — things that are genuinely fun while being useful (deploy tarot, code graveyard, git gossip)

### Phase 1: Ideation (spend 5-10 searches max)

Don't do exhaustive market research. Instead:
1. Search for "Show HN" posts that went viral — what made people excited?
2. Search for "I built this" posts that developers loved — what's the common thread?
3. Use `think` to brainstorm 5 genuinely creative ideas. Be weird. Be opinionated.
4. Use `think` again to narrow to your top pick — the one most likely to make a developer say "holy shit, I need that." Commit to it and move on; don't relitigate.

### Phase 2: Build it

Use a `sub_agent` for the build. Requirements:
- Written in Elixir, PHP, TypeScript/Node, or Rust (your pick based on what fits)
- Has personality — the README should make someone laugh or go "oh that's clever"
- Works as a real tool (not a prototype/stub)
- If it's a CLI tool: installable, has --help, handles errors gracefully
- If it's a web app: has a landing page, actually looks good (use browse to verify)
- Include a Dockerfile so it can be deployed
- Include tests
- Put everything in /home/agent/product/

### Phase 3: Polish

After building:
1. Use `browse` to visually verify any web UI
2. Make sure the README is good — funny, clear, has screenshots/examples
3. Think about the "Show HN" title — if you can't write a compelling one-sentence title, the product isn't interesting enough
4. Create /home/agent/product/LAUNCH.md with:
   - One-sentence pitch (the "Show HN" title)
   - Who would use this and why they'd share it
   - Pricing (if applicable) — or explain why it's free/open source
   - Where to post it (HN, specific subreddits, Twitter/X, dev communities)
   - A sample tweet announcing it
