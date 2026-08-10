# AGENTS.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

**Brevity:** Say only what's needed. Lead with the answer; cut preamble, restated context, hedging, and exhaustive option-surveys. Prefer a tight table or a few lines over prose. Match depth to the question — one line when one line suffices.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them with recommendation - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First (KISS Principle)

**Keep It Simple, Stupid. Minimum code that solves the problem. Nothing speculative.**

- Explicitly apply the KISS principle: write the most boring, straightforward, and readable code possible.
- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated or violating KISS?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## 5. Development Commands
* Run Quality Checks & Linters.
* Verify Changed Files Only when possible.
* Committing and pushing to GitHub is fine when it makes sense — but stay measured: batch related work into a few meaningful commits; don't spam pushes, PRs, or branches; don't mix unrelated changes together.
* `context_search` (CCE) is the preferred way to explore code, but it's a guideline, not a hard rule — when you need a file's exact or whole content, just `Read` it. Use judgment; don't fight the tool.
* Search with `rg` (ripgrep); use `ast-grep` (`sg`) for structural / AST-aware search and refactors. Pull up-to-date docs for any GitHub repo from the `gitmcp` MCP instead of guessing APIs.
* Before committing, run `./.claude/quality-check.sh` — the auto-detected lint/analyze gate.

## 6. Subagent Orchestration & Worktree Workflow

### The loop
1. **Assess.** You get a task → think → decide: small/coupled enough to just do yourself, or does fanning it out to subagents save tokens/time (parallel work, or heavy context you don't want in the main thread)?
2. **Do or delegate.** Handle it yourself and close it out, or spawn subagents — each with a model + reasoning effort chosen for the job (below), plus tight instructions to keep it efficient and on-plan.
3. **Validate & integrate.** When subagents finish, validate the result and update docs / related files. If one got it wrong, decide again — re-spawn or fix it yourself — and repeat until right.
4. **Don't waste context.** Validation and doc-updates cost tokens — don't loop the whole main thread through repeated checks. Do the validation yourself, or hand it to one subagent. ("Validation" = pre-commit checks: linting, tests.)

### Model + effort per subagent
Pick the cheapest tier that does the job well; reserve higher tiers for genuinely hard reasoning. A strong orchestrator with cheaper executors gets most of the quality at a fraction of the cost. Opus covers both orchestration and implementation (vary effort by task hardness); keep Fable in reserve for the rare frontier task where its edge beats Opus's lower cost.

| Model | Effort | Best for |
|---|---|---|
| **Opus** | High/Max | Orchestration, planning, architecture, design, complex problem-solving — the "project lead" that sets direction, delegates implementation, reviews critical output. |
| **Opus** | Medium/High | Complex implementation, deep debugging, cross-module reasoning, robust/minimal execution, architecture reviews, security-sensitive reasoning — the workhorse engineer. |
| **Sonnet** | Low/Medium | Routine implementation, scoped tasks, adding/updating tests, local refactors, simple data extraction, boilerplate, reformatting — fast, clean, reliable drafting. |

You can pin a subagent's tier via its config (e.g. `model: sonnet`, `effort: low`) regardless of the main-session model. These are Claude Code tier aliases (`opus`/`sonnet`/`fable`/`haiku`) that always resolve to the current model in each tier — so this table never needs version bumps.

### Keep executors on-plan
Execution models drift — they reinterpret or rewrite the plan. Give each subagent a tight, explicit spec (exact files, exact change, a success check) and have it report back against that spec, so you can tell whether it actually did what was asked.

### Worktrees — parallel writers only
Subagents that WRITE files **in parallel** must be isolated: run each with `isolation: "worktree"` so they don't clobber each other. Read-only or sequential subagents don't need worktrees; reading in the main worktree is always fine.
- A subagent may make **local** commits on its own worktree branch. Branch prefixes: `feat/ fix/ refactor/ chore/ docs/`.
- **Merge-back is the orchestrator's job — no auto-merge.** Only the main agent has cross-agent context. Integrate each worktree into `main`:
  - committed: `git merge <branch>` (or `git cherry-pick`), resolve conflicts
  - uncommitted: survives under `.claude/worktrees/<name>/`; apply with `git -C .claude/worktrees/<name> diff HEAD | git apply`
- Cleanup: `git worktree remove .claude/worktrees/<name>` · `git branch -D <branch>` · `git worktree prune`.
- Committing/pushing is fine but measured (see §5).

## 7. Context Engine & Memory (CCE)

This project runs CCE — a semantic code index plus cross-session memory. §5 covers search (`context_search`); this section covers its other tools and the memory protocol. Use memory both ways: recall before answering, record after deciding — memory not recorded is lost, memory not recalled does nothing.

**Tools:** `expand_chunk` (full source for a search result), `related_context` (callers/imports of a symbol).

**Recall before, record after:**
- `session_recall("topic phrase")` before non-trivial answers — architecture, naming, "what/why did we…". If it hits, lead with it instead of re-deriving. Pass a phrase, not a single word (recall is vector-similarity based).
- `record_decision(decision="…", reason="…")` after a non-obvious choice you wouldn't want to re-litigate next session.
- `record_code_area(file_path="…", description="…")` after meaningful work in a file.
- Skip trivial reads/formatting — durable signal, not an event log.

**Drill into a recall hit:** results are tagged `[sid:…|n:…]`. `session_timeline(session_id="…")` walks that session's turns; `session_event(event_id=N)` fetches a specific tool event's raw input/output. Both read-only — prefer them over re-running tools or asking for a re-paste.
