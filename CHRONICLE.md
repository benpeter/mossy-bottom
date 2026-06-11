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

## 2026-06-11 04:59 CEST - The chain killed itself, and the kill came from its own new test (bitzer)

At 00:40 the previous chain went dark - not paused, not stuck, but gone: the tmux
server itself was torn down. The cause was friendly fire from the very slice being
worked. #21's first slice added a heartbeat-window collision-safety test (case H in
bin/barn.test.sh) that stands up a throwaway tmux session, naming it in a variable
`hb_sess`. The case ends by resetting `hb_sess=""`. The test's EXIT trap then ran
`tmux kill-session -t "$hb_sess"` - and an empty `-t` does not no-op; tmux resolves
it to the CURRENT session. The current session was the chain's own. So the cleanup
meant to reap one scratch session instead killed the live chain and the server under
it. The Farmer reproduced this empirically.

Two Farmer-side edits close the wound, both now folded into #21 slice 1 and proven by
a 42/42 green suite:

1. The trap guards the kill: `[ -n "$hb_sess" ] && tmux kill-session ...`. An empty
   handle can never again resolve to the live session. This is the load-bearing fix -
   a test harness that can kill its own chain is a standing hazard to every future run.
2. A second, smaller relaunch hazard surfaced in the same territory: barn.sh raised the
   heartbeat window with `tmux new-window -t "${session}"` - the no-colon form, which
   tmux reads as "the index after the active window", not "anywhere free in this
   session". At relaunch that collided live with the known "index 1 in use" case. The
   target is now `"${session}:"` - bind to the session, let tmux place the window - which
   is exactly the #21 (the #18.2 residual) collision-safety the slice was chasing.

The fresh chain boots on the evolved prompts plus these two edits. #21 slice 1's work -
`resolve_hb_window` in barn.sh and case H in barn.test.sh - is in the working tree,
proof green; what remains is shaun verifying and accepting it, the artifacts and code
landing on origin, and the queue carrying forward. The lesson banks under Safety and
Robustness: a self-evolving harness has to treat its own test cleanup as part of the
blast radius, because here it was.
