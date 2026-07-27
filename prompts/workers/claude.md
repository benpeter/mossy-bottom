# Worker dialect: Claude Code

shaun reads this alongside `prompts/shaun.md` when the worker runs Claude Code.
It describes the pane you are watching, not the agent you are running. The rest
of shaun.md holds unchanged.

## Her pane

- **Idle** is the fenced empty `❯` box with the mode line below it:
  `⏵⏵ bypass permissions on (shift+tab to cycle)`.
- **Working** puts a spinner ABOVE the box, with an elapsed timer and
  `esc to interrupt`.
- Her status line carries `Context: N%`. That is a real reading and you can use
  it for compaction cadence.
- She marks an assistant turn with `⏺`.

Classify with timmy, not by eye. timmy speaks both dialects and needs no flag.

## Compaction

`/compact <keep-string>` takes a focus string, so you can steer what survives.
Send it while she is idle. The compaction section in shaun.md applies as written.

## Questions

She has permission prompts, so not everything that looks like a question is one
for you. A numbered selection menu is a tool gate; timmy reports that as
`waiting-input`. Prose ending in a question mark is a real question and timmy
reports `question`. Answer the second kind; the first resolves itself under
`--dangerously-skip-permissions`.

## Slash commands

One Enter submits.
