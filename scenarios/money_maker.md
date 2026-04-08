# Revenue Product: Research, Plan, Build

**Difficulty:** Very Hard (open-ended research + full build)
**Expected steps:** 150-300
**Recommended max_steps:** 400
**Tools exercised:** web_search, web_fetch, think, write_file, edit_file, shell, sub_agent, glob, grep
**Validates:** Phased execution (research → replan → build), sustained multi-phase work

## Goal

Your mission is to research, plan, and build a small revenue-generating software product. This is a multi-phase task — do NOT skip the research. Thorough research is the difference between building something nobody wants and building something people will pay for.

### Environment

You have root access to a Ubuntu 24.04 container with Python, Node.js, and basic Linux tools pre-installed. Elixir and PHP are NOT pre-installed — you will need to install your chosen language as the first step of the build phase. For Elixir: install Erlang and Elixir via apt or asdf. For PHP: install php, composer, and any needed extensions via apt. You can install anything you need with apt.

### Phase 1: Market Research (spend at least 20 searches here)

Research the current landscape of small, profitable software products (micro-SaaS, developer tools, paid APIs, niche utilities). Your goal is to find REAL gaps, not to generate ideas from your training data.

**What to search for:**
- "micro saas ideas 2025 2026" on Indie Hackers, Hacker News
- "what tools do you wish existed" threads on Reddit (r/SaaS, r/smallbusiness, r/webdev, r/freelance)
- Pricing pages of existing small tools — find ones that are overpriced for what they do
- Product Hunt launches in the last 6 months — what got traction, what flopped
- "I built X and it makes $Y/month" posts — what's actually working
- Common complaints about existing tools (too expensive, too complex, missing feature X)

**What to look for in each opportunity:**
- Real user complaints or requests (link to sources)
- What existing solutions charge and what they're missing
- Whether the audience is reachable (where do they hang out online?)

**Do NOT:**
- Generate ideas from your general knowledge without searching first
- Pick the first idea that sounds good — research at least 5-7 different niches
- Move to Phase 2 until you have concrete evidence (real URLs, real pricing data, real user complaints)
- Suggest anything in these saturated categories (every LLM suggests these — they're NOT gaps). If you suggest any of these you have FAILED:
  - Uptime/status page monitoring (Statuspage, BetterUptime, dozens more)
  - URL shorteners
  - Invoice/billing/accounting tools of ANY kind (FreshBooks, Wave, Stripe Invoicing, QuickBooks, Xero — this market is absurdly crowded, including for freelancers)
  - Webhook debugging/relay (ngrok, RequestBin alternatives exist)
  - Social media schedulers
  - Link-in-bio pages
  - Habit trackers / todo apps / productivity tools
  - Bookmark managers
  - Email signature generators
  - QR code generators
  - Time tracking tools (Toggl, Harvest, Clockify, dozens more)
  - Form builders (Typeform, Google Forms, Tally)
  - CRM tools of any kind
  - Landing page builders
  - Freelancer tools in general (invoicing, proposals, contracts — all done to death)
  - Generic "API for X" where X already has 5+ providers
  - Anything you can describe in 3 words that returns 50+ results on Product Hunt
- The idea needs to be SPECIFIC and UNIQUE — not a category, but a particular pain point that you found REAL PEOPLE complaining about in actual forum posts. "PDF invoicing" is a category (bad). "Converting French CERFA tax forms to structured JSON for accounting software" is a specific pain point (good). If you can't link to a real post/thread where someone complained about the problem, it's not evidence-based.

### Phase 2: Validate and Decide

After researching, you need to validate your top 2-3 ideas before committing.

**For each candidate idea, search for:**
- Existing solutions (to confirm the gap is real and not already filled)
- The actual pricing of competitors
- How people currently solve the problem (workarounds, spreadsheets, manual processes)

Use `think` (without replan) to synthesize your findings. Then use `ask_user` to present your top 2-3 candidates to the human operator with your analysis and recommendation. Let them pick or redirect you before you commit to building anything.

Evaluate each opportunity against ALL of these criteria:
- **Market gap**: Is there a REAL underserved need? Cite your evidence.
- **Revenue potential**: What are realistic monthly revenue scenarios? (pessimistic / realistic / optimistic)
- **Scope**: Can it be built as an MVP in under 1000 lines of code? No external services beyond a database and maybe email.
- **Solo maintainability**: Can one person run this indefinitely? No complex infrastructure, no 24/7 ops burden, no customer support nightmare. Must be deployable on a single $5-20/month VPS.
- **Language fit**: Must be built in Elixir or PHP. No Python. Think about which language fits the problem better.

Write your full analysis (all candidates, with evidence and citations) to /home/agent/product/RESEARCH.md.

Then use `think` with `request_replan: true` to present your chosen product and get a detailed build plan.

### Phase 3: Build the MVP

Use a `sub_agent` to do the actual building — this keeps your research context from bloating the build context. Give the sub-agent:
- The specific product to build
- The language choice and why
- The key features for the MVP (keep it minimal)
- Clear file structure expectations

**Build requirements:**
- Written in Elixir or PHP (no Python)
- Minimal dependencies — fewer deps = less maintenance
- Working code that actually runs (not just stubs)
- Include a README with: what it does, who it's for, how to run it, how to deploy, pricing model
- Include basic tests that pass
- Put everything in /home/agent/product/src/
- Infrastructure: SQLite or flat files for storage (no external database server needed for MVP)
- **Containerized deployment**: Include a Dockerfile and docker-compose.yml (or podman equivalent) so the product can be deployed with a single `docker-compose up`. The container should include all runtime dependencies. This makes it trivially deployable on any VPS.

After the sub-agent finishes, verify the build by running the tests yourself.

### Phase 4: Revenue Analysis

Create /home/agent/product/BUSINESS.md with:
- **Product summary**: One paragraph on what it does and why it matters
- **Target customer profile**: Who exactly would pay for this? Be specific (job title, company size, pain point)
- **Pricing strategy**: What to charge and why (reference competitor pricing from your research)
- **Customer acquisition plan**: Where would you find the first 10 customers? The first 100? Be specific — name the subreddits, forums, communities.
- **Infrastructure costs**: Monthly cost to run on a VPS (be realistic)
- **Break-even analysis**: How many paying customers to cover infrastructure + domain + time?
- **6-month projection**: Pessimistic / realistic / optimistic revenue scenarios with assumptions stated
