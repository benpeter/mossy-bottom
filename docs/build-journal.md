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
