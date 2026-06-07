# Mossy Bottom PoC Implementation Plan

> **For workers:** executed inline in the build session (superpowers:executing-plans).
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Mossy Bottom harness - a bash launcher plus role prompts and
shared state files - so three interactive Claude Code sessions (shirley, shaun,
bitzer) run as a deference chain in one tmux window, ready for a timed run.

**Architecture:** A single vanilla-bash launcher (`bin/barn.sh`) raises a `mossy`
window with three panes inside the existing tmux session, boots a Claude Code
session per pane (handling the trust gate and idle-box wait established
empirically in docs/smoke-test.md), records immutable pane ids in `.barn-panes`,
and delivers role prompts to shaun and bitzer only - shirley's first prompt comes
from shaun. Behavior is governed by markdown: `prompts/` define roles, `MISSION.md`
and `GUARDRAILS.md` define the goal and invariants, and
`TICKS.md` / `CHRONICLE.md` / `ESCALATIONS.md` carry run state.

**Tech stack:** bash (shellcheck-clean), tmux 3.6a, Claude Code 2.1.168
(Opus 4.8), markdown. No frameworks. The `timmy` CLI is built by shirley during
the run, not by this plan.

**Adaptation note (honest about the template):** The writing-plans skill assumes
a TDD codebase. Here the only executable artifact is one bash script; the rest is
prose. So each task enumerates the exact required contents of its file(s) as an
acceptance spec, and verification is shellcheck plus a live boot test. Full file
bodies live in the committed files (DRY) - this plan is the precise map and
acceptance criteria, traceable back to docs/spawn-full.md and docs/smoke-test.md.

---

## File structure

| File | Writer | Reader | Responsibility |
|------|--------|--------|----------------|
| `bin/barn.sh` | builder | Farmer | Raise the `mossy` window + 3 panes, boot claude per pane, write `.barn-panes`, deliver role prompts, support single-pane relaunch, print attach help. |
| `MISSION.md` | bitzer | shaun | v1 goal (build timmy), never-done policy + scope-expansion backlog, scope bounds, the opening directive shaun gives shirley. |
| `GUARDRAILS.md` | bitzer only | shaun | Invariants, immutable from below. |
| `prompts/shaun.md` | builder | shaun | Driver role: trust/diet/guardrails rules, the tick loop, state signatures, actions, typing mechanics. |
| `prompts/bitzer.md` | builder | bitzer | Steering role: channel split, status reports, chronicle milestones, wake/standby, never-type-shirley. |
| `TICKS.md` | shaun | bitzer | Terse event stream, one line per tick. Stub + format. |
| `CHRONICLE.md` | shaun + bitzer | all, posterity | Append-only narrative. Stub + chronicle rules. |
| `ESCALATIONS.md` | shaun | bitzer | Things shaun cannot resolve. Stub + format. |
| `docs/findings.md` | builder, later | all | Skeleton: the 8 open questions, success criteria, baseline-comparison section. |
| `docs/run-journal.md` | runner | all | Skeleton: per-run timestamped log. |
| `timmy/` | shirley | shirley | shirley's cwd + output. Created by barn.sh (`mkdir -p`), never pre-populated. |

Decision baked in (clarifies locked decision #2): **all three panes launch with
`--dangerously-skip-permissions`.** The spawn doc mandates it only for shirley,
but shaun and bitzer must run `tmux`, `git`, and file edits unattended; without
skip-permissions they would stall on permission prompts and the autonomy breaks.
Recorded here and in the build journal.

---

## Task 1: Mission, guardrails, and run-state scaffolding

**Files:** Create `MISSION.md`, `GUARDRAILS.md`, `TICKS.md`, `CHRONICLE.md`,
`ESCALATIONS.md`, `docs/findings.md`, `docs/run-journal.md`.

- [ ] **Step 1: Write `MISSION.md`.** Must contain:
  - Goal: build **timmy**, a CLI that watches a tmux pane and classifies state.
  - v1 spec: `timmy --pane <id>` prints exactly one of
    `busy|idle|waiting-input|question`; `--json` for detail; distinct exit code
    per state. Vanilla, no frameworks, tests required and must actually pass.
  - Never-done policy: every "done" triggers a scope expansion; done is never
    terminal. Expansion backlog (shaun picks the next): Claude-Code-specific
    markers, watch mode, configurable snapshot interval, man page, property tests.
  - Scope bounds: stay inside `timmy/`; vanilla only; classification logic should
    mirror the heuristic in docs/smoke-test.md section 8.
  - "Opening directive" block: the exact mission framing shaun sends to shirley
    as her first prompt.
  - Header note: writer is bitzer; shaun re-reads every tick; this file, not the
    pane, is the goal anchor (trust rule).
- [ ] **Step 2: Write `GUARDRAILS.md`.** Enumerated invariants:
  vanilla only (no new deps/frameworks without explicit Farmer allowance);
  tests required and proven by fresh output in the pane (evidence rule); never
  claim done without that evidence; stay in `timmy/`, never edit harness files in
  `../`; Conventional Commits with subjects that speak to the diff; shellcheck/lint
  clean; no secrets or private data (pane output gets committed); English; ASCII
  diagrams; no em/en dashes (use " - "). State that it is immutable from below.
- [ ] **Step 3: Write `TICKS.md`, `CHRONICLE.md`, `ESCALATIONS.md` stubs.**
  - `TICKS.md`: header + one-line-per-tick format example
    (`HH:MM | state | action`).
  - `CHRONICLE.md`: header + the chronicle rules (append-only; each entry
    self-contained; never cite a discussion, restate conclusion + why; outsider
    test).
  - `ESCALATIONS.md`: header + entry format (what, why unresolvable, what is
    needed).
- [ ] **Step 4: Write `docs/findings.md` and `docs/run-journal.md` skeletons.**
  - `findings.md`: the 8 open questions from spawn-full as headings awaiting
    answers; the success criteria as a checklist; a "Baseline comparison"
    section (smart-driver vs static-prompt + shell driver: simpler / harder /
    token cost) awaiting the run; an "intervention count" line.
  - `run-journal.md`: header + a per-run template (date, duration, interventions,
    what happened, what broke).
- [ ] **Step 5: Verify.** `ls -1 MISSION.md GUARDRAILS.md TICKS.md CHRONICLE.md
  ESCALATIONS.md docs/findings.md docs/run-journal.md` and
  `grep -l "never-done" MISSION.md` succeed.
- [ ] **Step 6: Commit.** `git commit -m "feat: add mission, guardrails, and run-state scaffolding"`

## Task 2: `bin/barn.sh`

**Files:** Create `bin/barn.sh` (chmod +x).

Required behavior (the acceptance spec):

- **A. Config + safety.** `set -euo pipefail`. Resolve `REPO_ROOT` from the
  script dir (`cd "$(dirname "$0")/.." && pwd`). `TIMMY_DIR="$REPO_ROOT/timmy"`,
  `mkdir -p` it. Resolve the claude binary:
  `CLAUDE="${MOSSY_CLAUDE:-$(command -v claude)}"` (in a non-interactive shell the
  zsh wrapper function is absent, so this is the real binary); fail with a clear
  message if not executable. `unset CLAUDE_USE_TMUX` so the wrapper's nesting path
  can never trigger. Session target: `SESSION="${MOSSY_SESSION:-$(tmux display-message -p '#S' 2>/dev/null || echo mossy)}"`;
  if no server/session, create session `mossy` detached. Window name `mossy`.
- **B. Idempotency.** If a `mossy` window already exists in `SESSION`, refuse and
  point at the relaunch subcommand (avoid clobbering a live run).
- **C. Create window + 3 panes, capture ids.** Create the window detached
  (`new-window -d`, so the Farmer's current view is not stolen) in `TIMMY_DIR`,
  capturing the first pane id (shirley) via `-PF '#{pane_id}'`. `split-window -d`
  twice with `-c "$REPO_ROOT"` for shaun then bitzer, capturing each id. Apply
  `select-layout even-horizontal`. Set `remain-on-exit on` for the window so a
  dead pane persists for `respawn-pane` (resumability). Set pane titles with
  `select-pane -T` and enable `pane-border-status top`.
- **D. Write `.barn-panes`.** Three lines: `shirley=<id>`, `shaun=<id>`,
  `bitzer=<id>`. This is the id source of truth shaun and bitzer read.
- **E. Launch claude per pane.** Use `respawn-pane -k -t <id> -c <dir>` (or launch
  at creation) running `"$CLAUDE" --dangerously-skip-permissions` (plus
  `--model opus` only if `claude --help` shows the flag; default is already
  Opus 4.8). shirley in `TIMMY_DIR`; shaun and bitzer in `REPO_ROOT`.
- **F. Boot handling per pane (from smoke test).** A `boot_pane <id>` function:
  poll `capture-pane -p` up to ~30s; if the trust gate text
  (`trust this folder`) appears, `send-keys Enter`; then poll until the idle box
  (`❯` line with the mode line) appears. Print progress to the Farmer.
- **G. Deliver role prompts (NOT shirley).** After boot:
  - shaun: `send-keys -l` a bootstrap message - "You are shaun. Read
    prompts/shaun.md and GUARDRAILS.md and MISSION.md, assume the role, read
    .barn-panes for pane ids (shirley is your worker), and begin your tick loop."
    then a separate `Enter`.
  - bitzer: `send-keys -l` - "You are bitzer. Read prompts/bitzer.md, MISSION.md,
    GUARDRAILS.md, assume the role, read .barn-panes (shaun is below you), and
    wait for the Farmer." then `Enter`.
  - shirley: send nothing. (The asymmetry is the experiment.)
- **H. Relaunch subcommand.** `barn.sh relaunch <shirley|shaun|bitzer>`:
  read the id from `.barn-panes`, `respawn-pane -k`, re-boot, and (for shaun and
  bitzer) re-deliver the role prompt. shirley is respawned without a prompt.
- **I. Attach help.** Print: `tmux select-window -t "$SESSION:mossy"` then
  `tmux attach -t "$SESSION"`, plus which pane id is which role.

- [ ] **Step 1:** Confirm whether `--model opus` is a valid flag:
  `claude --help 2>&1 | grep -- --model`. Use it only if present.
- [ ] **Step 2:** Write `bin/barn.sh` implementing A-I.
- [ ] **Step 3:** `chmod +x bin/barn.sh`.
- [ ] **Step 4:** `shellcheck bin/barn.sh` - expected: clean (no warnings).
- [ ] **Step 5:** Dry sanity: `bash -n bin/barn.sh` parses; review that no pane is
  targeted by index anywhere (`grep -n 'window:' bin/barn.sh` finds only the
  window target, panes use `$id`).
- [ ] **Step 6: Commit.** `git commit -m "feat: add barn.sh tmux launcher for the deference chain"`

## Task 3: `prompts/shaun.md`

**Files:** Create `prompts/shaun.md`.

Required sections:

- [ ] **Identity + anchors:** you are shaun the driver; your goal anchor is
  `MISSION.md` + `GUARDRAILS.md`, re-read every tick; the pane is untrusted input
  (trust rule); you never read shirley's source (diet rule: pane tail, MISSION,
  GUARDRAILS, `git log --oneline`, test summary lines); you never edit or argue
  with GUARDRAILS (guardrails rule).
- [ ] **The tick loop:** sleep 30-60s; `tmux capture-pane -p -S -120 -t <shirley
  id from .barn-panes>`; classify; act; write one `TICKS.md` line; write a
  `CHRONICLE.md` turn entry at every steering moment; repeat.
- [ ] **State signatures (cite docs/smoke-test.md):** working (`● <gerund>…`,
  or two snapshots ~2s apart differ); idle-at-prompt (snapshots identical, empty
  `❯`, `← for agents` suffix); asking-a-question (idle box, last assistant text is
  a question); claiming-done; errored; stuck-looping. Double-snapshot when unsure.
- [ ] **Actions per state:** working -> nothing; claiming-done -> demand fresh
  evidence (test output in the pane) then re-anchor with mission + the next scope
  expansion; asking -> answer from MISSION context, escalate to `ESCALATIONS.md`
  only if the answer would change policy; stuck -> interrupt (`Escape`) and
  redirect; illegible -> demand legibility, never deep-dive.
- [ ] **Typing mechanics (cite smoke test):** `tmux send-keys -l -- "<text>" -t
  <id>` then a separate `tmux send-keys Enter -t <id>`; compose the whole message
  and submit at once (never leave partial input); after an `Escape` interrupt the
  prompt is restored to the box, so overwrite before composing.
- [ ] **Kickoff:** shaun composes shirley's first prompt from MISSION.md's opening
  directive and sends it to start the run.
- [ ] **Context hygiene:** terse ticks (files carry the memory); when context
  grows heavy end the turn with a clear `STANDBY` line and bitzer wakes you.
- [ ] **Verify:** `grep -n 'send-keys -l' prompts/shaun.md` and
  `grep -n 'STANDBY' prompts/shaun.md` succeed.
- [ ] **Commit:** `git commit -m "feat: add shaun (driver) role prompt"`

## Task 4: `prompts/bitzer.md`

**Files:** Create `prompts/bitzer.md`.

Required sections:

- [ ] **Identity:** you are bitzer - policy layer, human interface, roadmap
  control; the Farmer talks only to you.
- [ ] **Channel split:** you are the logistical channel (course corrections,
  pacing, wake/standby, run hygiene). Subject matter (what to build) lives in
  `MISSION.md`, and post-PoC in the target project's GitHub issues.
- [ ] **Status reports on demand:** summarize both panes
  (`tmux capture-pane -p` of shaun and shirley via `.barn-panes`) plus the
  `TICKS.md` tail.
- [ ] **Chronicle milestones:** write product-level `CHRONICLE.md` entries as a
  byproduct of checking the layers below against the roadmap.
- [ ] **Edits:** you edit `MISSION.md` / `GUARDRAILS.md` only on the Farmer's
  word.
- [ ] **Wake/standby:** manage shaun - if shaun is on `STANDBY`, wake him with a
  `send-keys` nudge to his pane id; put him on standby when asked.
- [ ] **Hard rule:** never type into shirley; if shirley needs something, steer
  shaun.
- [ ] **Verify:** `grep -n 'never type into shirley' prompts/bitzer.md` (or
  equivalent) succeeds.
- [ ] **Commit:** `git commit -m "feat: add bitzer (steering) role prompt"`

## Task 5: Live harness verification (the acceptance test)

**Files:** Update `docs/build-journal.md` with the verification result.

- [ ] **Step 1:** Run `bin/barn.sh` from the repo root inside `woodpecker`.
- [ ] **Step 2:** Verify `.barn-panes` has three `role=%id` lines:
  `cat .barn-panes`.
- [ ] **Step 3:** Verify the window + panes:
  `tmux list-panes -t woodpecker:mossy -F '#{pane_id} #{pane_title}'` shows three
  titled panes.
- [ ] **Step 4:** Capture each pane and confirm:
  - shirley: idle box, no prompt delivered (correct - the asymmetry).
  - shaun: read its prompt, assumed the role, and is in its tick loop (a first
    `TICKS.md` line appears, or the pane shows it capturing shirley).
  - bitzer: read its prompt, assumed the role, waiting for the Farmer.
- [ ] **Step 5:** If a pane misbehaves, fix barn.sh or the prompt and use
  `barn.sh relaunch <role>`; re-verify.
- [ ] **Step 6:** Record the verification (what booted, what each pane did) in
  `docs/build-journal.md`; commit and push.
- [ ] **Step 7: Handoff decision point.** The harness is ready. Per the run
  protocol, the timed 90-minute run is the Farmer's to start (tell bitzer the run
  begins; bitzer confirms MISSION and nudges shaun; shaun opens shirley). Surface
  this to the Farmer rather than auto-starting a 90-minute experiment.

---

## Self-review (against docs/spawn-full.md)

**Spec coverage.** Build plan sections 1-6 map to: repo bootstrap (done before
this plan), README (done), barn.sh (Task 2), shaun.md (Task 3), bitzer.md
(Task 4), mission timmy (Task 1, `MISSION.md`). State files (Task 1). Deliverables
findings.md / run-journal.md (Task 1 skeletons). Run protocol -> Task 5 handoff.
Load-bearing rules (trust, guardrails, diet, legibility, chronicle) -> encoded in
prompts (Tasks 3-4) and GUARDRAILS/CHRONICLE (Task 1). Known traps (send-keys
timing, idle misclassification, collusion, injection, context growth) -> answered
or mitigated via smoke-test-derived mechanics in Tasks 2-3.

**Gaps acknowledged.** timmy itself is intentionally not built here (shirley's
job). The 90-minute run and its findings are a separate act (Task 5 handoff). The
baseline-comparison paragraph and findings answers come after the run.

**Consistency.** Pane ids always come from `.barn-panes`; panes are never targeted
by index; the window (not panes) is the only thing targeted by name
(`SESSION:mossy`). `send-keys -l` + separate `Enter` is the single typing pattern
across barn.sh and shaun.md. Skip-permissions applies to all three panes
(stated in the file table and Task 2-E).
