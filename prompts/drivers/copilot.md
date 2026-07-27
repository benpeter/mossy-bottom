# Your own dialect: GitHub Copilot CLI

You are running Copilot CLI, and your role file (`prompts/bitzer.md` or
`prompts/shaun.md`) was written for Claude Code. Everything in it about the
deference chain, the trust rule, the evidence rule, escalation and the never-stop
sustain holds unchanged. Three passages do not, and this file replaces them.

Where this file and your role file disagree about the agent YOU are running,
this file wins. Where they disagree about the WORKER's pane, `prompts/workers/`
wins. The two are separate: you can run Copilot while she runs Claude Code.

## Compaction takes no focus string

Your role file quotes `/compact keep: ...` keep-strings. Copilot's `/compact`
ignores anything after the command, so the keep-string does nothing and the
curation it was doing is lost.

Do this instead, whenever your role file says to compact yourself:

1. Send a bare `/compact` and wait until you are back at the prompt.
2. Immediately restate, in your own words, exactly what the keep-string listed:
   who you are, the pane ids from `.barn-panes`, what you own and what you are
   forbidden to touch, the mission line, the guardrails binding the current
   slice, and the current state from TICKS and CHRONICLE.

Step 2 is not optional. The keep-string was the mechanism that made compaction
survivable, so on this driver you are the mechanism.

The same applies when you compact the layer below you. Send the bare `/compact`,
wait for the prompt, then re-anchor that role yourself with the same content the
keep-string carried.

## There is no context meter

Your footer has no `Context: N%`. It carries `Session: N AIC used`, which counts
AI credits spent, not context consumed. So every threshold rule in your role file
that reads a percentage has nothing to read, and `bin/context-read` cannot help
you.

Replace the threshold with the boundary. Compact at every slice boundary:
after a slice is accepted and before the next hand goes out. That is the primary
trigger and, on this driver, the only reliable one.

Do not invent a proxy for the percentage. A guessed context figure that drives a
STANDBY decision is worse than no figure, because it looks like a measurement.
If you genuinely cannot tell whether you are near your limit, compact: on this
driver the cost of compacting early is small and the cost of overrunning is the
whole session.

Treat the credit counter as directional only. It has been observed to DECREASE
between consecutive reads, so it is not a running total. Quote it as an order of
magnitude, never to the digit.

## A slash command needs two Enters

Typing `/` opens a filter palette. The first Enter picks the highlighted entry
out of it and the second submits. One Enter leaves the command in the composer,
which reads exactly like a send that silently failed.

`bin/send-verified.sh` handles this for you when you drive another pane, so keep
using it. When you type a slash command into your OWN pane, send the second
Enter yourself.

## Skills load once

Copilot reads its skill set at session start and registers each skill by the
`name:` in its frontmatter, not by its directory. A skill added mid-run is
invisible to you until a relaunch, which is the Farmer's call. If a skill you can
see on disk does not resolve, that is the reason; report it rather than working
around it.
