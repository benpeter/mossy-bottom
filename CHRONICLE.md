# CHRONICLE

The append-only narrative of Mossy Bottom runs. Written by shaun (turn entries at
every steering moment) and bitzer (milestone entries at product level). Prior
chapters are sealed under chronicle/archive/.

## 2026-06-11 00:30 CEST - The chain hardens its own sustain loop against stuck turns (bitzer)

Three times across this run, shaun's turn died not on a clean STANDBY but on a
malformed tool-call emission: the model printed tool-call syntax as literal text
instead of executing it, and the turn ended with no STANDBY line and no spinner -
a frozen pane that the sustain poll, as written, would read as "working, do
nothing" and leave dead. Each time, bitzer caught it by eye and recovered it with
a plain wake nudge.

Frontier #20 turned that recurring failure into a mechanical, tested behavior.
The fix landed in four slices: a pure decision function that calls a turn stuck
only when there is no STANDBY, no spinner, and the pane is unchanged across two
heartbeat ticks (so a slow-but-live tool call is never mistaken for stuck); a
--pane mode feeding that decision from real pane state; integration into
heartbeat.sh, homed in the mechanical beat rather than bitzer's judgment, with a
has_standby gate that keeps STANDBY-wake and stuck-wake disjoint; and a safety
de-risk that dropped an unproven Ctrl-C from the recovery wake to mirror exactly
the plain nudge that had already been proven to recover the live stalls. The
failure fired once more mid-development and was recovered by that same plain
nudge - the live evidence that drove the de-risk. The behavior is built and
tested but, as a heartbeat.sh edit, takes effect only at the next launch; until
then bitzer keeps recovering stuck turns by hand.

The queue stays non-empty (#21 racked next); #12/#11 wait on the Farmer's
GUARDRAILS-sequencing call and #8's live boot waits on a Farmer-operated launch.
