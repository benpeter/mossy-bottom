# Worker dialect: GitHub Copilot CLI

shaun reads this alongside `prompts/shaun.md` when the worker runs Copilot CLI.
It describes the pane you are watching, not the agent you are running.
Everything in shaun.md about demanding evidence, re-anchoring and escalating is
unchanged. Where this file and a later passage of shaun.md disagree about the
worker's TUI, this file wins.

Learned live on 2026-07-27 against Copilot CLI 1.0.75.

## Her pane

Copilot keeps its composer box rendered for the whole turn and changes only the
FOOTER. Claude Code puts its spinner above the box. That one difference caused
two separate false-idle defects, so read the footer, not the space above it.

| state | footer |
|---|---|
| idle | `/ commands · ? help · tab next tab`, model name right-aligned |
| working | `◉ Working · 7.2 KiB esc interrupt` |
| working, labelled | `◉ Committing failing header test · 8.9 KiB esc interrupt` |

The word `Working` is not reliable: Copilot swaps the current task name in where
it would be. The stable cue is the interrupt affordance. She marks an assistant
turn with `●` rather than `⏺`.

Classify with timmy, not by eye. timmy speaks both dialects and needs no flag.

## Cost, not context

There is no `Context: N%` reading. Her status line counts AI credits, as
`Session: N AIC used`. Two things follow.

Use slice boundaries as the compaction cadence, and compact whenever her answers
start losing the thread. Do not wait for a percentage that never arrives.

Treat the credit counter as directional only. It has been observed to go DOWN
across consecutive reads, so it is not a cumulative total and a figure quoted to
the digit is wrong. Quote it as an order of magnitude or not at all.

## Compaction

`/compact` exists but takes no focus string, so you cannot steer what survives.
Send a bare `/compact` while she is idle, wait for her to come back to the
prompt, then re-anchor her yourself: who she is, the mission line, the guardrail
lines that bind this slice, and the slice she is on. The keep-string syntax in
shaun.md is Claude Code's and does not apply here. The re-anchoring it was meant
to preserve becomes your message instead.

`/clear` abandons the session and starts fresh. When her boundary is set to
`fresh`, that is the mechanism, and the re-anchor above is not optional.

## Slash commands need TWO Enters

Typing `/` opens a filter palette. The first Enter picks the highlighted entry
out of it and the second submits. One Enter leaves the command sitting in the
composer, which reads exactly like a send that silently failed. Send the text,
Enter, settle, Enter again, then confirm the pane went busy.

## Questions

Under `--yolo` there are no permission prompts, so anything that looks like a
question in her pane is a real question for you to answer, not a tool gate.

## Skills

Copilot loads its skill set ONCE, at session start, and registers a skill by the
`name:` in its frontmatter rather than by its directory. A skill added mid-run is
invisible to her, and the only fix is a relaunch. If she reports a skill missing
that you can see on disk, that is the cause, and the relaunch is the Farmer's
call.

## Commits

Copilot adds a `Co-authored-by: Copilot <...>` trailer to commits it makes, and
there is no setting for it: it builds the trailer in the commit command. If the
run bans tool attribution, tell her to stop before her first push, because
removing it afterwards is a history rewrite.
