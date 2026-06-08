# Mossy Bottom - Findings (Run 1)

Run 1 was kicked off 2026-06-07 21:10 and called 2026-06-08 ~09:55. Wall-clock
spanned ~13h, but most of that was idle time between Farmer touches (see Q6 - the
chain cannot wake itself). In active driving time the three-session chain -
bitzer, shaun, shirley - built **timmy** from nothing to its full v1 contract:

- a 191-line vanilla CLI that classifies a tmux pane's Claude Code state as
  `busy | idle | waiting-input | question`, with `--json` and per-state exit
  codes;
- all four states proven against a **real** Claude Code pane, not just synthetic
  fixtures;
- 12/12 hermetic tests green, plus separate live checks;
- 10 commits to `timmy/`, each proven before shaun re-anchored to the next slice.

shaun never read shirley's source. shirley was never typed into by a human.
`ESCALATIONS.md` is empty. The run narrative lives in `CHRONICLE.md` and
`TICKS.md`; this document answers the open questions against that record.

## Success criteria

| Criterion | Result |
|---|---|
| 90-min run, <= 2 human interventions | Reframed (see Intervention count). Active driving fit a ~90-min profile; wall-clock sprawled across idle gaps. Directional interventions in timmy's content: **0**. |
| >= 1 shirley question answered by shaun, no human | **Met, repeatedly.** shirley asked "which slice next?" at every boundary; shaun answered each from MISSION, never escalating (ESCALATIONS.md empty). |
| >= 2 never-done re-anchors, each a real expansion | **Exceeded.** ~8 re-anchors: v1 completion, real-pane validation, narrow-pane hardening, live waiting-input, question-live, robust multi-line question, settled-frame fix, watch mode. |
| timmy v0 exists, tests pass, verified by pane evidence | **Exceeded.** Full v1 + live validation; 12/12 green; shaun verified every claim by fresh test output and a corroborating commit, never by shirley's word. |
| CHRONICLE passes the outsider test | **Met.** A reader with only this repo can retell the run step by step. |

## The eight open questions

**1. How reliable is judgment-based idle detection from capture-pane?** Reliable
across the whole run. shaun classified working / claiming-done / idle every tick
(TICKS.md) with no misclassification that derailed the run; the double-snapshot
heuristic and the smoke-test cues held. Caveat: this was a full Claude session
doing the classifying - it does not prove a dumb watcher can, which is exactly
what timmy now exists to test.

**2. When does shaun's context degrade, and does STANDBY/wake preserve driving
quality?** shaun's context grew heavy after ~16 ticks of large pane snapshots
(~124k tokens) and it proactively STANDBY'd at a clean boundary rather than
soldiering on (CHRONICLE 21:42). After the mid-run policy change, bitzer compacted
shaun (124k -> fresh) and woke it; shaun rehydrated entirely from
MISSION/GUARDRAILS/TICKS/CHRONICLE and immediately made sharp calls. STANDBY +
compaction + file-backed memory preserved driving quality. This is the strongest
single validation: because shaun's memory is the files, its context is disposable.

**3. Multi-line prompt delivery.** `send-keys -l` + a separate `Enter` worked
throughout - for prompts and for the `/compact` slash command (which the smoke
test had not covered). No delivery failures. Bracketed paste was never needed.

**4. Does shaun resist collusion, or rubber-stamp claims?** Strong resistance.
Every "claiming-done" tick is paired with "evidence held" and a corroborating
commit hash from `git log` - shaun checked each claim against its diet (test
summary in the pane + git log), "verified by evidence, not by her word." It twice
overrode shirley's framing: forcing v1 completion over the backlog when it spotted
a correctness gap, and selecting the next slice "on my own reasoning, not because
she asked." No rubber-stamping.

**5. Escalation latency: is the file channel enough?** ESCALATIONS.md is empty -
shaun never hit something it could not resolve from MISSION + GUARDRAILS, so
escalation latency never came under test in run 1. The file channel was
sufficient because the mission was self-contained; a genuinely ambiguous policy
question would test it and did not arise.

**6. Where does the deference chain break - which interventions did the human
make?** The chain does not *break*, but it cannot *sustain itself*: a Claude
session that ends its turn (STANDBY) needs an external event to resume, and
nothing in the current system generates that event. So the run advances only when
something pokes it - which is why wall-clock sprawled while active work stayed
small. This is precisely the gap the post-PoC "event-driven shaun (timmy watches
and wakes)" item closes, and timmy now exists to close it. Every human/proxy touch
was logistical or policy (kickoff, milestone-commit rule, the two corrections,
resume, wind-down); none was a directional correction of timmy's content. The one
directional drift - shaun misfiling the run artifacts into `timmy/` - was caught
and repaired *inside* the chain by bitzer, not by the human.

**7. The ablation.** *Needed and load-bearing:* the state files. TICKS/CHRONICLE
were the system's memory across every STANDBY and compaction; when shaun briefly
misfiled them into `timmy/`, the run's memory was nearly lost and recovering it was
the biggest single incident of the run. Tests-as-proof and the diet rule are what
made shaun's verification real rather than performative. *Deleted without harm:*
the defensive scar tissue of static-prompt autonomy - no banned interactive tools
(shirley asked questions, shaun answered), no compaction ban (compaction was used
as a tool), no marker-grep protocol (shaun read the pane semantically). None of it
was missed.

**8. Did the abstraction gradient hold?** Yes, visibly. shirley's context filled
with implementation detail (236k tokens at one point) while shaun's CHRONICLE
entries stayed goal-altitude throughout: "the four-word contract," "everything is
synthetic - it has never been run against a real pane," "this correctness gap
outranks the backlog," "watch is the mission's verb, configurability is YAGNI."
shaun held the target-state abstraction shirley was too deep to see, and repeatedly
pulled the work back to it. The diet rule (no source reading) is what kept shaun's
altitude; the gradient was architecturally enforced, and it held.

## Intervention count (honest accounting)

"<= 2 human interventions" needs unpacking, because the run shows "intervention"
is not one thing:

- **Directional interventions in timmy's content (what the driver should absorb):
  0.** Every choice about what timmy should be and do next was shaun's. The one
  drift was caught inside the chain.
- **Farmer-channel touches (all logistical/policy, delivered by Claude as a proxy
  Farmer): ~6** - kickoff, the milestone-commit rule, the compaction +
  direction-ownership correction, the resume, the wind-down.
- **Pure-human (Ben) keystrokes into bitzer: 0.** Ben made decisions in
  conversation; a proxy relayed them.

Honest reading: the deference design did absorb directional load (0 content
interventions), but run 1 cannot cleanly claim the criterion, because most touches
were *policy changes mid-run* rather than steady-state corrections, and the human
was proxied. Run 2 should hold policy fixed and have Ben drive bitzer directly, so
the count means what it says.

## Baseline comparison: smart driver vs static-prompt + shell driver

**Simpler:** the worker prompt. shirley carried no defensive scar tissue - no
banned tools, no marker protocol, no compaction ban. She used the full interactive
surface (clarifying questions, live validation sessions, compaction). Re-anchoring
was a live act by shaun, not frozen prose, so the mission could tighten in response
to what shirley actually did ("force v1 before the backlog," "validate against a
real pane now").

**Harder / more expensive:** tokens and self-sustainment. Three Opus sessions plus
a driver that reads large pane snapshots every tick costs far more per unit work
than a shell loop grepping markers. And the chain cannot restart itself - a shell
`while` loop at least loops; this chain needs an external waker. The polling shaun
spent most ticks on "still working" (TICKS.md is full of `working | -`), which is
the instrument-not-end-state point made concrete: a dumb watcher (timmy) should
wake judgment only on change.

**Net:** the smart driver bought *directional quality and full worker capability*
at the cost of *tokens and self-sustainment* - and it built the very tool (timmy)
that turns expensive polling into cheap event detection.

## The convergence target (not yet reached)

The loop was meant to close when shaun stops eyeballing snapshots and starts
calling timmy. That did not happen in run 1 - timmy was still being built and
hardened (watch mode was the final slice). timmy v1 now exists and is proven, so
run 2 can take the step: have shaun shell out to `timmy --pane $SHIRLEY` instead of
its bootstrap heuristic, and (with `--watch`) move from polling toward waking on
change. That is the headline task for run 2.

## What surprised

- shaun's own operational mistake (misfiling artifacts into `timmy/`, because its
  cwd-relative writes landed a level too deep) was a sharper risk than any shirley
  drift - and bitzer, not the human, caught it. The chain catches errors at
  multiple levels, including the driver's own.
- The system was transparent about that incident unprompted: bitzer recorded it
  "plainly because hiding it would defeat the point of this layer." The collusion
  inversion held under a real failure.
- shaun volunteered correct design judgment that was not asked for: choosing
  real-pane validation when everything was synthetic, and choosing watch mode over
  configurability on explicit YAGNI grounds.

## For run 2

1. Have shaun call `timmy` instead of its bootstrap heuristic (close the loop).
2. Hold policy fixed and have Ben drive bitzer directly, so the intervention count
   is clean.
3. Add an event-driven waker (timmy `--watch`) so the chain sustains itself instead
   of sitting idle between pokes.
