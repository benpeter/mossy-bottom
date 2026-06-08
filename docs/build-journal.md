# Mossy Bottom - Build Journal

Public, append-only record of how this project went from the spawn prompt
(docs/spawn-full.md) to a planned, executed PoC. This is the "how we got here"
companion to the design docs and to the run-time CHRONICLE.md.

- This journal documents the **build** - turning the prompt into a working system.
- CHRONICLE.md documents the **runs** - what the agents did once the system runs.

Newest entries at the bottom. Each entry is self-contained: a reader with only
this repo can follow the construction story without any chat transcript.

---

## 2026-06-07 20:34 CEST - Kickoff: go received, scope confirmed

**What happened.** The Farmer (Ben) approved the locked design in
docs/spawn-full.md and gave the go to build. No brainstorming - the design is
locked.

**Two standing requests from the Farmer.**

1. Keep the entire experiment inside the existing tmux session `woodpecker` (on
   the Mac Studio at home), so it stays reachable over a remote reattach while
   the Farmer travels. `TMUX` was unset in the builder's shell so tmux can be
   driven from inside the session.
2. Document the journey publicly and transparently - not only the README and
   the design, but the path from prompt -> plan -> execution. Hence this journal.

**Environment verified (evidence before claims).**

- tmux 3.6a. Sessions present: `woodpecker` (attached, hosts this builder) and an
  unrelated `marlin` (left untouched).
- claude 2.1.168. The shell `claude` is a function that force-adds
  `--dangerously-skip-permissions` and can spawn its own tmux session; the real
  binary is `/Users/bp/.local/bin/claude`. barn.sh will call the binary directly
  to control flags per pane.
- gh 2.92.0 authed as `benpeter` (ssh). git identity `Ben Peter
  <bp@ben-peter.com>`.
- Working directory `~/github/benpeter/mossy-bottom` existed but was empty and
  not a git repo.

**Decision - amendment to locked decision #4 (tmux topology).** The spawn doc
locks "one session `mossy`, one window, three panes." To satisfy request (1),
the three panes will instead live in a dedicated **window named `mossy` inside
the existing `woodpecker` session**, not a separate session. Rationale: a single
`tmux attach -t woodpecker` then gives the Farmer the builder plus the running
experiment in one place over SSH; a separate detached session would be a second
thing to find and attach to. Everything else about decision #4 stands (plain
tmux, one window, three panes, no iTerm control mode). barn.sh will be written
to target a session (default: the current one) and create the `mossy` window
there, so the separate-session topology remains a one-line change if wanted.

**Approved nuances (confirmed at the go).**

- barn.sh bypasses the `claude` shell function and calls the binary directly.
- The repo is initialized in place in the pre-existing empty working directory
  rather than cloned into a subdirectory. Same end state.

**Build sequence committed to.**

1. First commit: design docs (full + caveman twin) + README + this journal +
   MIT license; then create the public GitHub repo and push, so the Farmer can
   check in remotely immediately.
2. Empirical smoke test in a `woodpecker` window: send-keys text + Enter timing,
   multi-line delivery, capture-pane fidelity during streaming, idle input-box
   appearance in captured text. Findings recorded here - they shape shaun's
   prompt.
3. Invoke the planning skill, commit the plan, then build barn.sh, the prompts,
   and MISSION/GUARDRAILS.

---

## 2026-06-07 20:47 CEST - Empirical smoke test complete

Ran the mandated smoke test in a detached `smoke` window inside `woodpecker`,
driving a scratch Claude Code session by `send-keys` / `capture-pane` exactly as
shaun will drive shirley. Full technical findings, with verbatim signatures, are
in docs/smoke-test.md. The scratch instance and its window were torn down
afterward; `woodpecker` is back to a single window.

**Headline findings, each of which shapes the build:**

- Boot has a trust-folder gate even with skip-permissions. barn.sh must accept it
  (send `Enter`) and then wait for the idle box before sending role prompts.
- Idle versus busy is reliably told by a double-snapshot: two `capture-pane`
  reads about 2s apart are identical when idle and differ when busy. Static cues
  back it up - an empty `❯` box with a `← for agents` suffix when idle, a
  `● <gerund>…` spinner when busy. The verb rotates, so this is judgment, not
  regex. This answers open question #1: judgment-based idle detection is feasible.
- Multi-line prompts (open question #3): `send-keys -l` with embedded newlines
  composes the block, and a separate `Enter` submits it as one message. Bracketed
  paste works as a fallback.
- There is no reliable single-key clear, so the discipline is to compose the whole
  message and submit it at once, never leaving partial input in the box.
- Interrupt is `Escape`. It also restores the interrupted prompt into the box, so
  shaun must overwrite before composing anew.
- Selection menus (the trust gate, and post-PoC permission prompts) are a
  distinct, mechanically detectable `waiting-input` signature.

Net result: the bootstrap heuristic is concrete, and timmy has a v0 spec
(snapshot diffing plus the state cues). Next: invoke the planning skill, commit
the plan, then build barn.sh, the prompts, and MISSION/GUARDRAILS.

---

## 2026-06-07 21:05 CEST - Harness built and verified live

Wrote the plan (docs/plan.md), then built the harness: MISSION.md, GUARDRAILS.md,
the TICKS/CHRONICLE/ESCALATIONS state files, bin/barn.sh, prompts/shaun.md, and
prompts/bitzer.md - one commit each. One self-caught fix along the way: shaun's
boot message originally told it to auto-start driving shirley, which violates the
run protocol (Farmer -> bitzer -> shaun -> shirley). Corrected so shaun assumes
its role and waits for bitzer's "Begin the run" nudge.

Then ran the acceptance test - `bin/barn.sh up` with `MOSSY_SESSION=woodpecker`.
It raised window `mossy` detached (window 0, the builder, kept the active view),
created three panes, and wrote .barn-panes:

```
bitzer=%3  shaun=%4  shirley=%5
```

After about 60s each pane had booted (trust gate auto-accepted, idle box reached)
and assumed its role, verified by capturing each pane:

- **bitzer** read MISSION + GUARDRAILS, restated them, identified itself as the
  logistical channel, and is standing by for the Farmer: "I will not nudge shaun
  until you say the run starts."
- **shaun** read shaun.md, restated the trust/diet/guardrails rules, noted shirley
  is pane %5 (targeted by id), and is awaiting bitzer's go: "I will not jump in on
  my own; shirley starts empty by design." The fix held - shaun did not
  auto-start.
- **shirley** is idle with an empty input box, cwd `timmy/`, and NO prompt
  delivered. The asymmetry that defines the experiment is intact.

Two notes for the record:

- **Pane titles.** Claude overrides the tmux pane title with its own task summary,
  so the border labels are not the role names. Pane identity comes from
  .barn-panes, not titles, so this is cosmetic only.
- **Public hygiene.** The Claude boot splash carries a personal welcome line and
  the account email. They scroll off once work begins, and the run artifacts
  (CHRONICLE/TICKS) are prose written by shaun and bitzer rather than raw boot
  dumps, so they should not leak. Still, anyone committing raw `capture-pane`
  output from a run must trim the splash first; the captured snippets in this
  repo's docs are sanitized accordingly.

**State:** the chain is UP and WAITING in `woodpecker:mossy`. The harness is
verified. Per the run protocol, starting the timed run is the Farmer's call -
attach and tell bitzer the run starts. Nothing auto-runs until then.

---

## 2026-06-08 03:55 CEST - Course-corrections: context management and direction ownership

Run 1 has been live (kicked off 2026-06-07 21:10). It is validating itself:

- **The chain self-corrected a drift.** shirley had shadowed the run artifacts as
  `timmy/CHRONICLE.md` and `timmy/TICKS.md`. shaun caught it, had them migrated
  back to the root, and a guardrail was added forbidding the shadow (commits
  `4b1e4ca`, `3f27021`). No Farmer was involved - exactly the directional catch
  the driver is supposed to make.
- **shaun manages its own context.** It proactively ended a turn with `STANDBY` at
  a clean slice boundary when its context grew, rather than soldiering on degraded.

Two corrections the Farmer asked for, now applied:

1. **Context management (compaction).** Verified against the Claude Code docs:
   `/compact <focus>` accepts free-text focus instructions; the footer
   `Context: N%` is context USED (climbs toward ~85-90%, where Claude
   auto-compacts); `/compact` sent via `send-keys` works on an idle pane, not
   mid-turn. Policy now in the prompts: shaun compacts shirley (targeted, while she
   is idle, when high); shaun ends with `STANDBY (context)` when its own context is
   heavy and bitzer compacts shaun before waking; the Farmer compacts bitzer by
   typing `/compact` directly into bitzer's pane (the Farmer types into bitzer
   normally - `send-keys` is only for cross-pane). Auto-compaction is the backstop
   throughout.
2. **Direction ownership.** shirley had begun proposing the next slice ("my
   recommendation for next..."). MISSION.md now states that shirley reports what
   she proved plus blockers, but does not pick the next slice - shaun selects from
   the backlog, and shirley's direction suggestions are noise to set aside (trust
   rule).

**Change-management protocol (the meta-question: how to brief changes so they are
transparent and trackable).**

- **The ledger is git.** Every change is a Conventional Commit; the history is the
  transparent, trackable record. No side channel needed for the record itself.
- **Propagation to a live run depends on what each agent re-reads.** shaun re-reads
  MISSION.md and GUARDRAILS.md every tick, so changes there reach the run within
  one tick (proven: the shadow-forbid guardrail propagated on its own). Role
  prompts (shaun.md, bitzer.md) are read once at boot, so a change there is
  propagated by a one-time re-read briefed through the steering channel
  (Farmer -> bitzer -> shaun). Re-reading the long role files every tick was
  rejected: it would bloat context, which is the opposite of what we want.
- **GitHub issues as a change channel: deferred (post-PoC).** The Farmer can
  already steer a live run remotely by attaching to bitzer over tmux. Issues only
  earn their keep once steering-without-attaching is needed (for example filing a
  change from a phone, which shaun would pick up via `gh` at each re-anchor without
  a local pull). Kept on the roadmap, not built now.
