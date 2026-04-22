# Context-Driven Development

A methodology for building software with AI agents. The repo accumulates context that makes every future decision and every future agent session better. This document is the methodology reference. Other repos can adopt this workflow by copying the folder structure, skills, and conventions described here.

## The Idea

Every piece of thinking gets written down in the repo. Decisions, plans, domain knowledge, research, design conversations, experiments. The repo isn't just where the code lives. It's the complete picture of the project: what was decided, why, what was built, and what's next.

This accumulated context is what makes the methodology work. Agents build well because the context is there. Humans make good decisions because the context is there. Nobody reconstructs the picture from Jira tickets, Slack threads, and tribal knowledge. The repo IS the picture.

### Context Layers

The repo organizes context into layers, each serving a different purpose:

| Layer | What it contains | Who it serves |
|-------|-----------------|---------------|
| **Specs** | Domain knowledge: what the system is, why each piece exists, the rules | Agents implementing, humans deciding |
| **Proposals** | Decision records: what was decided, why, what alternatives were rejected | Future agents and humans understanding intent |
| **Plans** | Execution blueprints: how to build something, broken into phases | Agents executing work |
| **Research** | External knowledge: platforms, competitors, patterns, vendor evaluations | Anyone making informed decisions |
| **Transcripts** | Design conversations: the thinking that shaped the specs | Anyone who needs the "how we got here" |
| **Experiments** | Prototypes and POCs: things we tried, what we learned | Anyone evaluating feasibility |
| **Code** | The implementation: how things actually work | Agents building, humans debugging |

No single layer tells the whole story. Together they form a complete picture that any agent or human can navigate.

### The Specificity Gradient

Each layer operates at a different level of specificity. The idea sharpens as it moves through the pipeline, from a vague direction to exact implementation:

| Layer | Specificity | What it sounds like |
|-------|-------------|---------------------|
| **Blueprint** | 3/10 | "We're building an intake flow with 7 steps, SimpleBridge integration, deploy to Render" |
| **Proposal** | 5/10 | "The Provider model needs these fields, conditions are a separate table because of X, the intake controller manages session state like this" |
| **Plan** | 8/10 | "Phase 1: run rails new, add these gems, create these migrations. Phase 2: build screening controller with these actions, these views." |
| **Code** | 10/10 | The actual implementation. Every edge case, every line. |

This gradient is deliberate. Each layer adds specificity that the previous layer intentionally left out:

- **Blueprints don't specify models** because the data model might change during proposal discussion.
- **Proposals don't specify file paths** because the plan needs to survey the codebase first.
- **Plans don't specify variable names** because the code will discover the right abstractions during implementation.

Trying to be too specific too early wastes effort. A blueprint that reads like a plan is over-specified: it locks in decisions before the thinking has been done. A plan that reads like a blueprint is under-specified: an agent can't execute it without guessing.

The right question at each layer:

- **Blueprint:** "Is the direction clear enough to write proposals?"
- **Proposal:** "Is the design clear enough to write a plan?"
- **Plan:** "Is the plan clear enough for an agent to execute without asking questions?"
- **Code:** "Does it work?"

Complex features naturally produce multiple proposals from one blueprint, and multiple plans from one proposal. A blueprint for "build the intake flow" might generate proposals for the data model, the UI, the integration layer, and the dashboard. The UI proposal alone might produce plans for the screening steps, the provider cards, and the booking confirmation. Each plan is a unit of work an agent can execute in one session.

### Why Context Accumulates

Each conversation, each decision, each implementation leaves behind artifacts that make the next round easier. A proposal written today becomes context for a plan tomorrow. A plan executed this week becomes an archived decision record next week. Research gathered for one feature informs the next proposal.

This is the flywheel: the more context in the repo, the better agents perform, the better the artifacts they produce, the more context accumulates.

### Specs and Code: Shared Authority

Think of specs like chapter summaries in a book. The summaries tell you what each chapter is about, why it matters, and how it connects to the rest. The chapters themselves contain the full detail. You'd never mistake one for the other, and you need both to understand the whole book.

**Specs are the domain authority.** They own intent, concepts, rules, relationships, and the reasoning behind decisions. What is this system? Why does each piece exist? What are the domain rules?

**Code is the implementation authority.** It owns how things actually work: method signatures, edge cases discovered during development, performance tradeoffs, the places where design met reality.

When they diverge on domain intent, the spec wins (update the code, or update the spec if intent changed). When they diverge on implementation detail, the code wins (the spec was never meant to track that level).

This means specs are not a replacement for code. You could not hand the specs to a new team and have them rebuild the system from scratch. That's not the goal, and pretending otherwise would bloat the specs with implementation details they shouldn't contain. A re-platforming effort would need both: specs to understand the domain model and decisions, code to understand everything discovered during implementation.

What the specs DO enable: someone can read `specs/` (or play with the running app) and understand the entire system at a conceptual level. They can make informed decisions about what to build next, what to change, and what the tradeoffs are. That's the real value.

### Two Audiences, One Repo

The same context serves both agents and humans, but from different directions:

- **For agents:** "Does this give me enough context to implement correctly without wrong assumptions?"
- **For humans:** "Does this let me understand the system without reading code?"

The agent goes from spec to code. The human goes from code (or the running app) back to understanding. The context layers sit in the middle, serving both.

## Repo Structure

```
project/
├── specs/              # Domain knowledge (what and why)
│   ├── schemas/        # Data model definitions
│   └── sandbox/        # Half-baked spec ideas, domain sketches
├── workflow/           # The decision and execution pipeline
│   ├── proposals/      # Decision pipeline (draft -> accepted)
│   │   └── accepted/   # Decision records with date prefix
│   └── plans/          # Execution plans (ready for audit or execution)
│       ├── active/     # Currently being executed (hands off)
│       └── archived/   # Completed plans with execution notes
├── source/             # All application code
├── research/           # Distilled external knowledge
├── docs/               # External-facing content
├── transcripts/        # Design sessions, call recordings
└── experiments/        # Prototyping, POCs, throwaway explorations
```

`specs/` contains domain knowledge and exploratory sketches (`sandbox/`). `workflow/` contains the pipeline that produces and maintains everything else.

**Why separate `source/` from root?** Keeps context and code at the same level. Agents can read specs without navigating into the app. Humans can browse the domain model without opening a code editor.

## Research

`research/` holds distilled knowledge about the world outside the codebase: platforms, competitors, compliance requirements, design patterns, and vendor evaluations. Each file covers one topic. Research is durable reference material that informs specs and proposals but is not itself a spec (it describes what exists, not what we're building).

Research files are updated as new information comes in. They don't follow the proposal/plan lifecycle. When research leads to a decision about what to build, that decision becomes a proposal.

## The Idea Pipeline

An idea moves through the repo as files in folders:

```
idea -> specs/sandbox/               (explore in writing, optional)
     -> workflow/proposals/          (formalize as proposal with rationale)
     -> workflow/proposals/accepted/ (decision made, date-prefixed)
     -> workflow/plans/              (break into executable phases)
     -> workflow/plans/active/       (agent is building it)
     -> source/                      (code lands)
     -> workflow/plans/archived/     (plan done, execution notes appended)
```

At any point, `experiments/` can feed into any stage. A quick POC in experiments might validate a proposal's assumption or prove a plan's approach. `research/` can inform any stage too, providing external context that shapes decisions.

Each step produces context that persists. A sandbox sketch that gets rejected is still useful: it records what was considered and why it didn't move forward. An archived plan records what was built and what was learned during execution.

## The Proposal Pipeline

Two tracks depending on the size of the change:

```
Big features:  propose -> accept -> audit -> execute -> reconcile -> merge
Ad-hoc work:   hack on branch -> reconcile -> merge
```

| Stage | What Happens | Skill | Artifacts |
|-------|-------------|-------|-----------|
| **Propose** | Write rationale, design, scope. What problem, what changes, what doesn't change. | manual or agent | `workflow/proposals/feature-name.md` |
| **Accept** | Human approves. Proposal moves to `accepted/` with date prefix. Agent surveys codebase and writes execution plan. | `/accept-proposal` | `workflow/proposals/accepted/YYYY-MM-DD-feature.md`, `workflow/plans/feature.md` |
| **Audit** | Agent verifies plan is ready: checks dependencies exist, test data is sufficient, open questions are resolved. Creates experiments for POC gaps. | `/audit-plan` | Readiness Audit section appended to plan |
| **Execute** | Agent moves plan to `active/`, works in a git worktree, implements phases, runs tests, updates specs, archives plan, opens PR. | `/execute-plan` | Branch with code + archived plan + PR |
| **Reconcile** | Agent diffs the branch against specs, finds post-plan drift (UI tweaks, bug fixes, late additions), proposes spec updates. | `/reconcile` | Spec edits committed to branch |
| **Merge** | Human reviews PR, squash-merges to master. | manual (or `/nightshift` auto-merge) | Code on master, plan in `archived/` |

For ad-hoc work (bug fixes, small tweaks, exploratory changes), skip propose through execute. Work on a branch, then run `/reconcile` before merging to keep specs current. The reconcile skill works with or without a plan.

The reconcile step is what keeps context accurate. Without it, specs drift from code and the accumulated context degrades. Reconciliation is the maintenance cost of CDD. It's worth paying because stale context is worse than no context.

### Plan Lifecycle (Filesystem State Machine)

```
workflow/plans/plan.md           Ready. Audit can check it. Execute can pick it up.
       │
       ▼
workflow/plans/active/plan.md    In flight. Execution agent is building it in a worktree.
       │                         Other agents: hands off this plan.
       ▼
workflow/plans/archived/plan.md  Done. Execution notes appended. Decision record.
```

The folder IS the state. No database, no status field, no API call. Agents check folder contents to determine what's available, in progress, or done:

- **Audit agent:** only looks at `plans/*.md` (ignores `active/` and `archived/`)
- **Execute agent:** picks up from `plans/*.md`, moves to `active/` as first step
- **Other agents:** see a plan is gone from `plans/` and know not to re-execute it

### Proposals as Decision Records

Accepted proposals stay in `workflow/proposals/accepted/` permanently, date-prefixed (e.g., `2026-03-14-daily-capacity-planning.md`). They document **why** a decision was made. Plans document **how** it was built. Together they form a complete decision record that future agents and humans can reference.

## Multi-Agent Execution

Multiple agents can work concurrently, each with a role:

```
master branch (working tree)
├── audit agent        reads plans, checks readiness
├── proposal agent     writes proposals from requirements
├── bash agent         ad-hoc commands, exploration
│
└── worktree branch (isolated)
    └── execute agent  implements a plan, commits to branch
```

### Why Worktrees

The execution agent makes lots of file changes and commits. If it works directly on master, it blocks other agents and creates merge conflicts. Git worktrees solve this by giving the execute agent its own isolated copy of the repo:

- The execute agent is spawned with `isolation: "worktree"` via the Agent tool
- It gets a temporary branch in its own directory on the filesystem
- Other agents continue working on the master working tree uninterrupted
- When execution is done, the branch is pushed and a PR is opened
- The worktree is automatically cleaned up

This is important for the day/night workflow: during the day you might have an audit agent checking plans while a proposal agent drafts something new. Neither is blocked by an execute agent doing heavy implementation work.

### Agent Roles

| Agent | Reads | Writes | Isolation |
|-------|-------|--------|-----------|
| **Audit** | Plans, code, data files | Appends audit to plan file | Main (small writes) |
| **Proposal** | Specs, code, screenshots | New proposal files | Main (new files only) |
| **Execute** | Plan, specs, code | Everything in source/ | Worktree (heavy changes) |
| **Reconcile** | Specs, code, branch diff | Spec file edits | Branch (targeted edits) |
| **Bash** | Anything | Ad-hoc | Main |

### Execution Flow

1. Audit agent checks the plan on master (`workflow/plans/`), marks it READY
2. Orchestrator moves the plan to `workflow/plans/active/` on master, commits, pushes
3. Execute agent spawned with `isolation: "worktree"`
4. Execute agent reads the plan, creates tasks, implements all phases
5. Execute agent runs tests and linter, commits per phase
6. Execute agent updates specs to match what was built
7. Execute agent moves plan to `workflow/plans/archived/` with execution notes
8. Execute agent opens a PR via `gh pr create`
9. Post-plan polish, bug fixes, UX tweaks (additional commits on branch)
10. `/reconcile` diffs the branch against specs, catches any drift from post-plan commits
11. PR is reviewed, rebased, and fast-forward merged to master
12. On merge: code lands, plan is in `archived/`, specs are current

**What the PR contains:**
- All code changes from the plan phases
- The plan file moved from `workflow/plans/` to `workflow/plans/archived/` with execution notes
- Updated specs from execution AND reconciliation

## Batch Execution (Nightshift)

The day/night workflow: spend the day planning, let agents execute overnight.

```
Day:     Write proposals, accept plans, audit plans, queue work in workflow/plans/
Night:   /nightshift picks up all queued plans and executes them sequentially
Morning: Review results, handle stuck plans, write new proposals
```

### How It Works

`/nightshift` is an orchestrator skill. It does not execute plans itself. It:

1. **Discovers** all ready plans in `workflow/plans/*.md`
2. **Orders** them (explicit dependencies first, then alphabetically)
3. **Confirms** the queue with the user (last human checkpoint)
4. **Loops** through each plan:
   - Moves plan to `active/`
   - Spawns an execute subagent in a worktree
   - If success: records the branch, sets it as the base for the next plan's PR
   - If stuck: moves plan back to queue with notes, continues to next
5. **Reports** results to `.claude/nightshift-report.md`

The result is a stack of PRs, each based on the previous one's branch.

### Why Sequential, Not Parallel

Plans are executed one at a time, each building on the merged result of the previous one. This is deliberate:

- **SQLite locks.** Only one process can write at a time. Parallel agents would deadlock.
- **Port conflicts.** Test suite and dev server share port 3000.
- **Merge conflicts.** Two branches touching overlapping files would need manual resolution.
- **Playwright/browser.** Only one browser session at a time for visual testing.
- **Cumulative correctness.** Plan B might depend on code that Plan A introduces. Sequential execution with auto-merge ensures each plan starts from the latest state.

### Stacked PRs

Each plan branches off the previous plan's branch, not master. This means plan B has all of plan A's code available even though A hasn't been merged yet. The PRs form a stack:

```
PR #1 (base: master)           <- merge this first
PR #2 (base: PR #1 branch)   <- builds on #1
PR #3 (base: PR #2 branch)   <- builds on #2
```

In the morning, review and squash-merge them in order. GitHub auto-rebases the next PR when its base is merged.

Nothing lands on master without human review. The agent does the work overnight; you do the review in the morning.

### Handling Failures

When a plan gets stuck (tests fail after 2 attempts, unresolvable blocker):

1. The execute agent returns with a summary of what it accomplished and what blocked it
2. The orchestrator moves the plan back from `workflow/plans/active/` to `workflow/plans/` on master
3. A note is added to the plan's revision log
4. The next plan in the queue is executed
5. The stuck plan appears in the morning report with details

The user deals with stuck plans the next day: fix the blocker, re-audit, re-queue.

## Monitoring Execution

During execution (daytime or nightshift), the execute agent writes progress to `.claude/execution-status.json` at the repo root (gitignored). This file is updated after each task starts, completes, or when the phase changes.

```json
{
  "plan": "spec-overhaul",
  "status": "executing",
  "current_phase": "Phase 2: Dashboard Spec",
  "current_task": "Rewrite dashboard.md",
  "tasks_done": 3,
  "tasks_total": 7,
  "thinking": "Trimming helper method catalog, keeping domain rules",
  "last_message": "Tests: 152 pass, 0 fail",
  "recent_activity": [
    "Rewrote session_engine.md (no changes needed)",
    "Trimmed data_model.md from 156 to 95 lines",
    "Tests passing after Phase 1"
  ],
  "last_update": "2026-03-15T03:30:00Z"
}
```

Run `sdd-pulse-tui` in another terminal to watch progress live. It reads this JSON file and displays a dashboard with plan name, current task, progress bar, and recent activity. Useful during nightshift to check on things before bed, or during daytime execution to see where the agent is.

Status values: `executing`, `testing`, `linting`, `pushing`, `done`, `failed`.

## The Full Skill Chain

Skills are Claude Code slash commands that encode repeatable workflows. Each skill has a `SKILL.md` file in `~/.claude/skills/<name>/` with instructions the agent follows.

### Pipeline Skills

These form the core CDD workflow in order:

| Skill | Purpose | Input | Output |
|-------|---------|-------|--------|
| `/accept-proposal` | Approve a proposal, survey codebase, write execution plan | Proposal file | Accepted proposal + plan in `workflow/plans/` |
| `/audit-plan` | Verify plan readiness: deps, data, open questions, POC gaps | Plan file | Readiness audit appended to plan |
| `/execute-plan` | Implement a plan in a worktree: code, test, spec update, PR | Plan file | Branch with code + PR |
| `/reconcile` | Diff branch vs specs, fix post-plan drift before merge | Branch (auto-detected) | Spec edits committed |
| `/nightshift` | Execute all queued plans overnight as stacked PRs | All plans in `workflow/plans/` | Stacked PRs + morning report |

### Utility Skills

| Skill | Purpose |
|-------|---------|
| `/ltcp` | Lint, test, commit, push. Full quality checklist before any push. |
| `/save` / `/load` | Checkpoint working context to `CURRENT_CONTEXT.md` for session continuity. |
| `/proposal` | Generate a branded consulting proposal PDF from markdown. |

### Writing New Skills

A skill is a `SKILL.md` file with YAML frontmatter (`name`, `description`, `args`) followed by markdown instructions. The agent reads and follows these instructions when the skill is invoked.

Good skills are:
- **Deterministic where possible.** If the task is a script (API polling, file processing), write a script and have the skill orchestrate it.
- **Step-by-step.** Numbered phases the agent can follow without ambiguity.
- **Self-contained.** Include everything the agent needs to know. Don't assume context from a previous conversation.

## Markdown Format for Agents

Application views can serve structured markdown alongside HTML using Rails' `respond_to` with a registered `text/markdown` MIME type. Any view that has a `.md.erb` template will auto-render for `?format=md` requests.

```
curl "app.test/?format=md"                    # weekly dashboard as markdown
curl "app.test/?view=monthly&format=md"       # monthly report as markdown
```

The markdown is designed for agent-to-agent context passing, not human reading. It includes:
- **One-line summary** with key metrics up front (billable hours, target %, plan delta)
- **Flags** calling out anything notable (over target, behind pace)
- **Data tables** with inline context explaining what the columns mean
- **Condensed detail** (per-client daily totals, not individual session timestamps)

This enables agents to consume app data without browser automation or HTML parsing. An agent skill can `curl` the dashboard and get a complete briefing in a fraction of the tokens the HTML would cost.

### Implementation Pattern

1. Register the MIME type: `Mime::Type.register "text/markdown", :md`
2. Create `.md.erb` templates alongside `.html.erb` partials
3. Use presenters to hold data, templates for rendering (same pattern as HTML)
4. Controller just calls `render :show` and Rails picks the right template by format

## What Makes a Good Spec

Specs describe the domain. Code describes the implementation. A good spec stays one level of abstraction above the code: it tells you what the system is, why each piece exists, what the rules are, and how the pieces connect. Someone reading only the specs should understand the whole system conceptually. Someone reading only the code should be able to build and run it. Together, they're the complete picture.

Specs should be concise. They're summaries, not transcripts. If a spec is getting long, it's probably descending into code-level detail.

### The Litmus Tests

**For agents:** "Could an agent reading only the code make a wrong choice here?" If yes, the spec should mention it. If the code speaks for itself, the spec is redundant.

**For humans:** "Could someone reading this spec understand what the system does and make a good decision about what to change?" If not, the spec is missing domain context.

### What Belongs in Specs

**Domain rules and business logic.** The things that aren't obvious from reading code:
- "Internal hours are excluded from the billable Total" (why those rows are separated)
- "Trailing window with 10-min gap, boundary is `>` not `>=`" (the algorithm's edge case)
- "Sessions crossing midnight split into per-day entries" (a non-obvious behavior)
- "Override values take precedence over template defaults" (the precedence rule)

**Decisions with reasoning.** The "why not" is as important as the "what":
- "Template total IS the weekly target, not sum of client targets, because capacity planning should be independent of client mix"
- "Weekly chart removed, too distracting for a 7-day window"
- "Simple subtraction for available hours, no spreading or pacing" (the deliberate simplification)

**Non-obvious architecture.** Choices an agent might undo without context:
- "Singleton pattern for template (one row, `first_or_create!`)"
- "Idempotent import: delete all prompt entries in range, then recreate"
- "Double rAF for Turbo Frame layout timing" (with explanation of why)
- "JSON fetch per day, not Turbo Stream" (with explanation of the tradeoff)

**Worked examples.** Concrete illustrations of how rules play out. The session engine spec does this well: here are 4 prompts, here's the session that comes out, here's the edge case table.

**What each model IS and WHY it exists.** Not column definitions (that's `schema.rb`), but the model's role in the system, its relationships, and its domain rules.

### What Doesn't Belong in Specs

Everything an agent can derive from reading the code:

- **Column types, constraints, indexes.** That's `schema.rb` and the migration files.
- **Method signatures and return shapes.** Read the service or presenter.
- **CSS classes, colors, hover states.** Read the ERB and CSS.
- **Stimulus controller targets and actions.** Read the JS file.
- **Helper method catalogs.** Read the helper module.
- **Route listings.** Run `rails routes`.
- **Exact CLI command syntax.** Read the README or script.
- **Setup/install instructions.** Those belong in a README, not a spec.

### Spec Types and What They Contain

| Spec Type | Contains | Does NOT Contain | Example |
|-----------|----------|------------------|---------|
| **Algorithm** (e.g., session_engine) | Rules, worked examples, edge cases table, I/O contract | Implementation code, language-specific syntax | "Gap > 10 min ends session" with a 4-prompt walkthrough |
| **Feature** (e.g., dashboard) | What each section is for, domain rules (billable vs internal), key design decisions, architectural choices | CSS details, method signatures, HTML structure, helper listings | "Delta row: logged minus planned for completed days only" |
| **Data model** | What each model IS, why it exists, key relationships, domain rules | Column types, indexes, scope implementations, validation syntax | "TimeEntry: the atomic unit. Three sources feed the same pipeline." |
| **Integration** (e.g., calendar_sync) | Mapping rules, dedup contract, filtering logic, workflow | CLI flags, regex syntax, API field names | "Events matched by [tag] in summary. Deduped by gcal_id." |
| **Operations** | Architecture diagram, component relationships, troubleshooting | Setup commands, config file paths, exact log locations | "502 = Rails server not running" |
| **Design system** | Component catalog (what exists and when to use it), non-obvious UI decisions, conventions | Tailwind classes, ERB syntax, helper return values | "Double rAF needed for Turbo Frame positioning" |

### The Gold Standard

`session_engine.md` is the model spec. It has:
- The algorithm in plain language (4 steps)
- A worked example with concrete numbers
- An edge cases table covering boundary conditions
- The cross-repo merging rule and why it exists (prevents double-billing)
- The I/O contract (what goes in, what comes out)

It does NOT have: Ruby code, ActiveRecord syntax, test descriptions, or implementation details. An agent reading it knows exactly how sessions work. A human reading it understands the domain without opening a single source file. That's the right altitude.

## Per-Developer Weekly Todo

Each developer working in a CDD project keeps a running weekly/near-term todo at `.claude/WEEKLY.md` inside the repo. `.claude/` is gitignored, so the file is machine-local and private — every developer has their own view without stepping on anyone else's. Never commit it, never move it to the repo root.

The weekly todo is orthogonal to the formal proposal/plan pipeline above. Proposals and plans are the shared, durable record of what we're building and why. The weekly is the individual developer's scratchpad for what's in flight right now — Spruce API exploration to do, Yates conversations to carry, proposals waiting on a decision, that kind of thing. It exists because not every in-flight thread is worth a proposal, and because "what am I actually doing this week" is a question whose answer shouldn't live only in someone's head.

When the developer says "add to weekly" / "put that on my list" / "weekly todo":
- Read the existing file first. Don't overwrite it.
- Append or update the relevant section. Typical sections: `## This week`, `## Next up`, `## Conversations I'm carrying`.
- Bump the `Updated:` date at the top.
- If the file doesn't exist yet, create it with those three sections and today's date.

Freeform otherwise. Structure evolves with how the developer works.

## Archived Ideas

Ideas we tried and moved away from. Kept here so we don't re-invent them.

### _status.md tracking files (retired)

We experimented with `_status.md` files in spec folders to track what's built vs what's spec'd (checkbox lists updated via `/update-status`). This didn't work well:

- **Always stale.** The checkboxes were a cache of information already in the code and git history. Maintaining them was busywork.
- **Redundant with /reconcile.** The reconcile skill already catches spec/code drift at merge time, which is the actual problem status files were trying to solve.
- **Wrong abstraction.** "What should we build next?" belongs in proposals, not status files. A proposal captures the why. A status checkbox doesn't.

If you want to know what's built, read the spec and the code. If they diverge, run `/reconcile`.
