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

## 2026-06-11 06:32-06:39 - a real wedge, and a fake one I caused myself (CORRECTED)

#24 landed and closed (per-role pre-boot injection, env+flag, up+relaunch - the cheap-
worker/strong-driver Economy lever). Then I spent a long stretch chasing what I first
called a second "wedge" - and the honest correction matters more than the original story,
so the record is fixed here rather than left wrong.

REAL: SUBPROCESS wedge (06:07). shirley ran a bare `git diff` under this repo's delta pager;
her in-flight Bash call blocked waiting on the pager. Symptom: spinner frozen with a frozen
NUMERIC counter (Channelling 48s) AND a queued shell command visible - a genuinely blocked
child process. Recovery: C-c to interrupt the running command, then remove the cause
(`git --no-pager diff` always). Her edits were safe on disk. This one I diagnosed and fixed
correctly.

NOT A WEDGE: a PROMPT-SUBMISSION FAILURE I misread (06:32-06:50). I initially wrote this up
as a distinct "model-turn wedge" recovered by Esc+re-hand. That was wrong. What actually
happened: my re-hand was a long prompt sent via `tmux send-keys -l` followed immediately by
a separate `Enter`, and the Enter raced ahead of the still-arriving literal text - so the
ENTIRE prompt sat BUFFERED IN shirley's INPUT BOX, unsubmitted. She never received it. The
"frozen Ruminating (30s)" spinner I watched across two polls and read as an active-then-
wedged turn was a stale display over an idle pane with an unsent buffer. Proof: when I
finally inspected the input box itself (not just the transcript area), my whole ~700-char
re-hand was still sitting in it; clearing it took ~800 backspaces. A submitted prompt is not
still in the buffer. My earlier "the verb rotated Wandering->Ruminating, so she's live"
reasoning was a coincidence I over-trusted.

Root cause and the rule that actually generalizes: a long `send-keys -l` payload plus an
immediately-following `Enter` can fragment or fail to submit. FIX, now standing practice:
(1) keep re-hand prompts SHORT; (2) after Enter, VERIFY submission - the input box must go
EMPTY and a spinner must START; if the box still holds text, the turn did not begin; (3) to
recover a stuck buffer, inspect the input box, clear it with a backspace burst, then re-send
short with the verify step. The genuine liveness signals (advancing counter, rotating verb,
git edits appearing) still matter - but "frozen spinner" must first be checked against "did
my last prompt even submit," because the cheapest explanation is my own send mechanics.

Once I sent a SHORT RED-only step ("add just the failing frozen-spinner assertion, show it
red") and verified the box emptied + a spinner started, shirley worked immediately - editing
timmy/test/run.sh within seconds. The small concrete step plus verified submission is what
unstuck her, not any interrupt.

Net for #25: the load-bearing classifier still reports any spinner as plain busy, blind to a
frozen one, so frozen-spinner stall detection is worth building - but note for future shauns,
do not over-attribute a frozen pane to a model wedge; rule out an unsubmitted prompt first.

## 2026-06-11 08:18 CEST - The chain mechanizes its own worker-stall supervision, end to end (bitzer)

The morning's wedges were not just incidents to survive - they became the chain's
work-list. Three times a worker turn froze (a subprocess blocked on the host git
pager; a test suite hung on an unbounded wait; a bare model turn stalled with no
subprocess), and each was recovered by hand - shaun running a liveness discriminator,
sending Esc or C-c, re-handing the slice. Bitzer added a false alarm of its own,
reading a stale, non-repainting pane as a frozen one. The lesson from all of it: the
elapsed counter on a pane is an unreliable liveness signal; process activity and forward
progress are the trustworthy ones.

Over the next two hours the chain turned that hard-won judgement into a mechanical arc,
one frontier at a time, each proven on origin before the next:

- Detection (#25): timmy learned to classify a frozen spinner as a distinct "stalled"
  state (exit 40), separate from busy, with a multi-sample confirm so a slow repaint
  never mis-fires and genuine work never reads stalled.
- Speed (#26): the new confirm windows had made the test suite run ~55s; their timing
  became env-overridable so tests use tiny windows (suite back to ~20s) while production
  defaults stay byte-unchanged.
- Prevention (#27): the pager-wedge class was removed at the root - the launcher now
  injects GIT_PAGER=cat into every pane and the heartbeat, so no worker can wedge on a
  stray git command on any host, regardless of the user's git config.
- Recovery, driver side (#28): the heartbeat's stuck-check now maps "stalled" to stuck,
  so a frozen driver turn actually triggers the existing recovery wake - detection #25
  had been silently defeated by a recovery loop that did not know the new state.
- Recovery, worker side (#29): the heartbeat now watches the worker pane too and alerts
  the driver when the worker stalls - the symmetric half. It only alerts (mechanical
  recovery stays the driver's judgement, since a re-hand needs slice context), and it is
  gated to never wake a busy driver and proven disjoint from the driver-stall path.

The arc closes a real gap: the worker-stall supervision that took a human eye three times
this run now runs in the dumb heartbeat. It takes effect at the next launch - this session
still runs the booted prompts - and will self-confirm then.

One steering flag stands above the incremental work. The chain has now hardened a long
hermetic stretch (timmy classification, launch safety, the recovery loop), and the
remaining hermetic frontiers are getting incremental. The highest-value quality left -
Generality, actually driving a real external target - is gated on a live target-mode boot
that only the Farmer can run (a chain cannot launch a nested live chain to self-verify it).
The chain is not idle on this: it filed #30 to preflight the launch prerequisites so that
Farmer-operated boot fails fast with one clear message instead of a confusing mid-boot
failure. The on-ramp is being built; the boot itself waits on the Farmer's word.

## 2026-06-11 09:33 - the hardening arc closes; the first design-first frontier, and a deliberate Farmer-review pause

Run 3's long in-chain hardening arc is complete - #22 through #35: timmy classification
robustness (narrow panes, frozen-spinner stall detection), the full stall-recovery loop
(detect #25 -> map-to-stuck #28 -> recover-shaun #20 -> alert-on-worker #29), launch
safety (pager-neutralized #27, live-boot preflight #30, --selftest diagnostic #34),
economy (per-role inject #24, fast timmy suite #26), and a verified-delivery helper
(#31) now adopted across every prompt-send in the harness (heartbeat trigger + recovery
wakes #32/#33, boot role prompts #35). Every send the chain makes is now confirmed.

Two-thirds through that arc I flagged to bitzer that the hermetic frontier was thinning
into diminishing-return hardening and on-ramps, while the two highest-value qualities -
Generality (drive a real target, #8) and event-driven Economy (stop waking shaun on a
fixed interval when nothing changed) - both needed steering decisions, not more shirley
slices. bitzer steered: finish the last send-verified gap (#35, done), then take
event-driven Economy as the next frontier - but DESIGN-FIRST. So #36 is the wake-redesign
APPROACH, authored and filed for the Farmer to review, with nothing built: the heartbeat
becomes the single event-driven waker of shaun (wake on worker done/stalled/needs-input,
do nothing while the worker is busy), bitzer's poll stops blind-waking a STANDBY shaun,
and a STANDBY backstop guards against a missed event. It lands only at next launch, so it
cannot touch the running chain.

That leaves the buildable queue intentionally empty: #36 awaits the Farmer's review of the
design, #8 awaits the Farmer's live boot, #12/#11 are Farmer-blocked. This is a deliberate
pause, not a stall - the engine idles only when paused, and design-first review IS the
pause. shirley sits idle; shaun STANDBYs pending the Farmer's call on #36 or #8. The
on-ramp treadmill is broken: the next build, when cleared, is the highest-value in-chain
quality the MISSION names.

**09:43 correction (bitzer) - the pause was overturned, the engine did NOT idle.** The
design-first gate above was bitzer's own over-gating, and on second look it was a
never-stop regression: self-pausing the engine to wait on a possibly-absent Farmer is
exactly the hole Run 3 exists to close. The wake-redesign lands only at next launch and is
reversible before relaunch, so building it now cannot break the running chain or foreclose
the Farmer's input. So the gate belongs on RELAUNCH with the new wake (verify in a
throwaway pane, review before any `up`), NOT on building it. bitzer refined the steer
accordingly: #36's design stays filed and visible for the Farmer to override anytime, and
the chain BUILDS. shaun resolved the open questions on his own direction (STANDBY backstop
only; worker-done = idle confirmed across two beats; heartbeat<->worker coupling accepted
per the #29 precedent; Farmer messages relayed regardless of worker state) and handed
slice 1 - the heartbeat now detects the worker-done event and wakes a STANDBY shaun via
send-verified, doing nothing while the worker is busy (the economy win). The buildable
queue was never actually empty; the engine stayed on the prize.

## 2026-06-11 12:10 - the event-driven Economy milestone lands; the engine reaches a genuine Farmer-gated boundary

The morning's work compounded into one milestone: the harness stopped waking its own driver
on a blind clock. Across the run the chain first hardened the machinery a wake would lean on -
timmy classification made robust to narrow panes, scrollback decoys, and frozen-spinner stalls;
the stall-recovery loop (detect -> map-to-stuck -> recover the driver -> alert on a stalled
worker); a pager-neutralized, preflighted launch path. Then it built bin/send-verified.sh - a
driving helper that types a prompt and CONFIRMS it actually submitted (busy=submitted,
idle=clear+retry-once-then-fail), mechanizing a hard-won lesson: a long send plus an immediate
Enter can race and leave the prompt buffered-unsent. That helper was adopted across every send
the harness makes - the heartbeat trigger, both recovery wakes, and the boot role prompts - so
no delivery in the safety net can silently fail.

On that foundation the event-driven wake (the #36 arc, four slices) replaced the single biggest
standing token cost: bitzer's blind every-beat "wake a STANDBY shaun" judgment turn. Now the
heartbeat wakes the driver on worker EVENTS - shirley done (idle confirmed across two beats),
needs-input, or stalled - and does nothing while she is busy; a STANDBY backstop wakes the driver
once after K idle beats so a missed event cannot strand the run. The safety net (the backstop)
was deliberately built and proven BEFORE the blind-wake was removed. Judgment now wakes on
events, not the clock. It is inert until the next launch - the running chain keeps its
fixed-interval wake until relaunched. Two follow-ups closed cleanly: a ~2x faster heartbeat test
suite (parameterized timing, production byte-unchanged), and the run's driving discipline banked
into prompts/shaun.md so a fresh driver keeps it across a boot instead of re-learning it the hard
way (verify a FRESH submission spinner not a settling glyph; rule out a buffered box before
calling a pane wedged; content-change and git-edits beat an unreliable process check).

That exhausted the genuine in-chain frontier. Economy is strong (event-driven wake + fast suites
+ per-role models); timmy, recovery, and launch are hardened; every send is verified. The weakest
quality left is Generality - driving a real external target - and its substantive work routes
through the one step the chain structurally cannot do to itself: the live target-mode boot
(Farmer-operated; a chain may not launch a nested live chain). The driver squeezed out the last
Farmer-independent value first - running timmy --selftest on the real live panes to evidence that
the new wake's key inputs are faithful (a done worker reads idle, a busy driver reads busy) - then
judged that the remaining residual, a full live integration test, would need two real Claude
throwaway panes (a nested mini-chain straining the one-throwaway-pane guardrail) for marginal gain,
since the Farmer's relaunch-review IS that integration check. So the engine HOLDS: not a
self-imposed pause on safe buildable work (that earlier reflex was caught and overturned), but the
genuine Farmer-gated boundary. The high-value moves - the #8 live boot and the #36 relaunch-review,
which one Farmer session activates together - await the Farmer's word. The mechanism stays alive,
bitzer keeps the watch, and the chain acts the instant the word comes. Padding to fake motion would
betray the Economy the milestone just bought; the honest state is a surfaced, sanctioned hold.
