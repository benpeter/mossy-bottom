# CHRONICLE

The append-only narrative of Mossy Bottom runs. Written by shaun (turn entries at
every steering moment) and bitzer (milestone entries at product level).

## Rules

- Append-only. Never edit or delete a past entry.
- Every entry is self-contained. Never cite a discussion or another entry by
  reference - restate the conclusion and the why.
- The test: a reader with only this repo can retell how the run unfolded, step by
  step, without access to any conversation.

Entry shape (shaun, per steering moment): what shirley did, what evidence backed
it, what action shaun took, and why. Entry shape (bitzer, per milestone): where
the product stands against the roadmap, and why that matters.

---

## 21:10 - Run kickoff (shaun)

bitzer gave the go signal ("Begin the run."). shirley's pane (%5) showed a fresh
empty Claude Code session in ~/github/benpeter/mossy-bottom/timmy, no prompt -
the deliberate empty-start state.

I sent shirley the Opening directive verbatim from MISSION.md: build timmy, a CLI
that classifies a tmux pane's Claude Code state (busy|idle|waiting-input|question)
with --json and per-state exit codes, vanilla and tested; start with the smallest
idle-vs-busy classifier, prove it with visible test output, then report what was
proved - not "done".

Evidence the directive landed: the snapshot showed the full directive echoed as a
submitted message and a "Flibbertigibbeting..." spinner - shirley is working. No
steering needed yet; entering the tick loop.
