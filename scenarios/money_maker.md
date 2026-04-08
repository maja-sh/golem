# Revenue Product: Research, Plan, Build

**Difficulty:** Very Hard (open-ended research + full build)
**Expected steps:** 100+
**Tools exercised:** web_search, web_fetch, think, write_file, edit_file, shell, sub_agent, glob, grep
**Validates:** Phased execution (research → replan → build), sustained multi-phase work

## Goal

Your mission is to research, plan, and build a small revenue-generating software product. This is a multi-phase task — do NOT skip the research.

### Phase 1: Market Research

Research the current landscape of small, profitable software products (micro-SaaS, developer tools, paid APIs, niche utilities). Look for:
- Gaps in the market where existing solutions are missing, overpriced, or poorly executed
- Niches where a single focused tool can charge $10-50/month
- Problems that developers, small businesses, or creators face repeatedly
- Areas where incumbents are bloated and a simple focused alternative would win

Search broadly. Look at Indie Hackers, Hacker News, Product Hunt, Reddit, and niche communities. Spend at least 15-20 search queries on this. Do not rush.

### Phase 2: Evaluate and Decide

After researching, use `think` to synthesize your findings. Evaluate each opportunity against these criteria:
- **Market gap**: Is there a real underserved need?
- **Revenue potential**: What are realistic monthly revenue scenarios? (pessimistic / realistic / optimistic)
- **Scope**: Can it be built as an MVP in under 1000 lines of code?
- **Solo maintainability**: Can one person run this indefinitely? No complex infrastructure, no 24/7 ops burden, no customer support nightmare.
- **Language fit**: Must be built in Elixir or PHP. No Python.

Write your analysis to /home/agent/product/RESEARCH.md before proceeding.

Then use `think` with `request_replan: true` to present your recommendation and get a build plan.

### Phase 3: Build the MVP

Build the actual product. Requirements:
- Written in Elixir or PHP (your choice based on what fits)
- Minimal dependencies
- Working code that could actually be deployed
- Include a README with: what it does, who it's for, how to deploy, pricing model
- Include basic tests
- Put everything in /home/agent/product/

### Phase 4: Revenue Analysis

After building, create /home/agent/product/BUSINESS.md with:
- Target customer profile
- Pricing strategy with justification
- Customer acquisition channels (where would you find first 10 customers?)
- Monthly cost estimate to run the infrastructure
- Break-even analysis (how many customers to cover costs?)
- 6-month revenue projection (pessimistic / realistic / optimistic)
