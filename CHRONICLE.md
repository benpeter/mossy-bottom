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

---

## 2026-06-11 ~05:06-05:15 - resume: #21 accepted+closed, a misdirected #12 hand recovered, #22 derived

Fresh shaun booted after the 00:40 friendly-fire kill. bitzer's go directed a
VERIFY-AND-ACCEPT of #21 slice 1 (already in the working tree): I re-proved it from
the outside - shellcheck + bash -n clean, the hermetic suite 42/42 green including
case H (the four HB-window collision paths), and barn.sh up --plan exit 0 with the
heartbeat line intact - then committed 934ffea, staging only the two bin/ files. The
Farmer's two folded edits (raise the HB window at "${session}:" not "${session}"; guard
the test trap on [ -n "$hb_sess" ] so case H can never kill the live session) rode in
that one commit, sharing the files and the green suite. bitzer had already pushed to
0efb43e, so 934ffea was on origin and I closed #21 citing it.

Then I made an error worth recording. I picked the next slice from the open queue by
age (#8 oldest) without first reading the recent TICKS tail and ESCALATIONS, handed
shirley a #12 slice, and only afterward read the run-state that prior-shaun had left:
#12 is Farmer-blocked - its operational half landed long ago (85e0607) and its only
residual is a binding GUARDRAILS sequencing invariant, escalated at 19:09 as something
shaun cannot resolve from below; the 00:26 STANDBY said in plain words "do NOT work
#12/#11". shirley, behaving correctly, had already built and committed her slice
(bin/onorigin.sh + a hermetic test, 0efb43e) and bitzer had pushed it before I caught
the mistake. I did not rewrite the published history - that is bitzer's domain and the
guard is harmless - but #12 stays OPEN and blocked: an on-origin guard script does not
answer the binding question, so the now-public onorigin.sh sits unused, parked for
bitzer's #12 decision. The lesson banks under Legibility and Safety: the queue is not
the whole picture; the blocked-issue flags live in TICKS/ESCALATIONS and must be read
BEFORE selecting, not after the hand. A faster fix here would have cost shirley nothing.

With #21 closed and the entire open queue unworkable (#12/#11 Farmer-blocked, #8 the
Farmer-operated live-boot tracker), the never-empty-queue rule required a derived
frontier. I picked the weakest quality with the highest leverage: Robustness of timmy,
the load-bearing liveness classifier the whole tick loop rests on. The documented
narrow-pane idle residual (#17, parked under #8 for a live CHECK) has an in-chain,
hermetic FIX, so I filed #22 and handed slice 1 - reproduce the narrow-idle
misclassification as a failing assertion against a throwaway ~40-column idle-box
fixture (no claude launch), then make idle detection robust at that width without
regressing the wide-pane cases. I compacted shirley first (clearing the spent #12
context), waited for idle, passed the usage gate (5h 8%, weekly 4%), then handed. She
is working it now; I STANDBY with resume = monitor, not re-hand.

---

## 2026-06-11 ~05:32-05:36 - #22 accepted (narrow idle box, footer wrap), #23 derived from its residual

shirley delivered #22 slice 1 and I verified it from the outside rather than on her
word: shellcheck + bash -n clean, and the timmy suite 47/47 on my own run, including the
two new "#22 narrow WRAPPED-footer" assertions - a narrow idle box whose footer wraps is
now positively recognised as idle, and the '?' variant as a question. The load-bearing
check is that the SAFETY direction did not move: "#10 quoted idle box above a real busy
spinner -> busy" and every working case still classify busy, so the fix adds idle
RECOGNITION without ever mislabeling a live working pane idle. shirley's own report was
notably disciplined - she fixed box-recognition while refusing to flip the busy "decoy"
fixture to idle, naming that as the forbidden direction. c3ab523 is not yet on origin, so
the #22 close is deferred to a later tick (single-pusher invariant intact).

The interesting part was the residual. shirley flagged a "decoy" case - a working pane
whose capture contains idle-box chrome - that must stay busy and which she could not
resolve with a classifier tweak ("needs an evidence source beyond the capture"). That is
the very defect I had been hitting all run: while monitoring shirley, timmy repeatedly
returned idle with idle_box=true even though snapshots_differ=true and she was demonstrably
working - because her work was rendering idle-box fixtures into her own pane. A false-idle
on a live pane is the dangerous direction (a driver could treat a still-working worker as
finished), and it is content-shape-driven, not narrow-width - distinct from #22. So I
filed #23 (Robustness + Safety) with the safe direction stated: liveness must win over
static idle-box chrome, without regressing the settled-idle cases (a genuinely settled idle
box, and the #10 frozen-decoy-spinner, still read idle). I derived this frontier from
shirley's surfaced residual plus my own live evidence - exactly the "shirley reports
proof and blockers, shaun picks the next slice" division.

Operating note worth banking: throughout this stretch timmy's false-idle made its own
single-call idle reading untrustworthy for a worker that builds TUI fixtures, so I leaned
on a manual two-snapshot liveness check (capture, sleep 3, capture, compare) before
treating shirley as idle. That kept me from mistiming acceptance. #23 is the fix; until it
lands, the manual 2-snapshot guard is the standing workaround.

## 2026-06-11 06:02 - #23 closed; the structural frontier is thinning

#23 landed and closed on origin: persistent cross-snapshot motion now overrules idle-box
chrome, so a working pane that renders idle-box-shaped content reads busy. I proved it the
honest way after a false start - `git stash -- bin/timmy` stashed nothing (the fix is
committed, so there is no diff to stash; "No stash entries found", both runs green), which
would have rubber-stamped a non-proof. The valid red->green is `git checkout 1b8b8cf^ --
bin/timmy`: pre-fix timmy fails the two motion assertions (48/2), the fix passes (50/0),
and the static-box guard passing BOTH directions shows motion is the discriminator, not a
blanket idle_box override - so no settled-idle regression. Lesson banked: to re-prove a
COMMITTED fix red, check out its parent, never stash.

The more important arc signal came from deriving the next frontier. With #23 closed the
queue had nothing workable (#15 draft, #12/#11 Farmer-blocked, #8 Farmer-operated). I went
to derive a Generality frontier and verify-before-filing killed TWO candidates in a row:
the worker directive is already target-parameterized (shaun_boot sends the Opening
directive from ${state_dir}/MISSION.md, so a target supplies its own), and preflight_state
(barn.sh:314) already refuses to boot a target whose .mossy/ lacks MISSION.md+GUARDRAILS.md.
The target-mode structural surface is more built than the run's pace implied. Robustness
(timmy: 5 issues) and Autonomy (heartbeat: 3) are saturated; the genuine remaining
Generality work mostly routes through the one thing the chain structurally cannot do to
itself - the live target-mode boot (#8, Farmer-operated). What was left and workable was
the smallest, pre-acknowledged gap: #24, per-role pre-boot injection, named as deferred at
barn.sh:216 - a cheap-worker/strong-driver Economy lever that builds on #18.3. Handed
shirley slice 1 (env-based MOSSY_INJECT_<ROLE> only; flag parsing deferred). The standing
note for whoever derives next: the hermetic frontier is narrowing, and that is itself the
signal that #8's Farmer-operated live boot is becoming the gating dependency for the next
big tranche of Generality work.

## 2026-06-11 06:32 - two classes of wedge, and the recovery taxonomy

#24 landed and closed (per-role pre-boot injection, env+flag, up+relaunch - the cheap-
worker/strong-driver Economy lever). The day's real teacher, though, was the worker
wedging TWICE while I drove it, in two structurally different ways - and the distinction
is worth banking because the recovery differs.

SUBPROCESS wedge (06:07): shirley ran a bare `git diff` under this repo's delta pager; her
in-flight Bash call blocked waiting on the pager. Symptom: spinner frozen with a frozen
NUMERIC counter (Channelling 48s, unmoving) AND a queued shell command visible. There IS a
blocked child process. Recovery: C-c (interrupt the running command); then remove the
cause (`git --no-pager diff` always). Her edits were safe on disk.

MODEL-TURN wedge (06:32): shirley's turn hung mid-think with NO subprocess - just the
model/API turn stuck. Symptom: the spinner VERB frozen ('Wandering' for ~3.5min; a live
turn rotates the verb every ~15-30s), no advancing counter, and zero forward progress (git
clean, no edits). C-c is wrong (no command to kill); a plain wake is wrong (that is the #20
recovery for a turn that has ENDED at an idle prompt - here the turn is still ACTIVE).
Recovery: Esc to interrupt the active generation, then re-hand the slice. Context survives,
and since git was clean nothing was lost.

The discriminator that took patience to trust: a genuine long think and a model-turn wedge
both show a static 'thinking' pane. What separated them was the spinner VERB rotation (live
turns rotate it; the wedge froze it) plus zero progress over minutes. I waited the full
~3.5min before interrupting precisely so I would not abort a real design-think - the frozen
verb + no progress is what finally crossed the line. Triage rule banked for future shauns:
frozen numeric counter + blocked command -> C-c; frozen spinner VERB + no subprocess + no
progress -> Esc + re-hand; ended idle prompt + no STANDBY -> plain wake (#20).

This entire stretch WAS the manual wedge-classification that #25 exists to push into timmy -
the load-bearing classifier today reports any spinner as plain busy, blind to a frozen one.
Handing #25 (frozen-spinner stall detection) was thus self-justifying: I was paying its
cost by hand, twice, in one chapter.
