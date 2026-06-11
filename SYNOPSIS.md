# SYNOPSIS

The milestone arc of Mossy Bottom - a bounded index over the dated archives, not
a transcript. Maintained by bitzer at each rotation and each milestone. The
rehydration entry point: a fresh shaun rehydrates from this plus the most recent
chapter, never the whole archive.

Each entry: date (from `date`, never guessed), what landed, what was proved, and
which chapter holds the detail.

---

## 2026-06-10 - Run 3: self-evolving harness (engine + steering overlay)

Detail sealed in chapter `ticks/archive/2026-06-10.md` +
`chronicle/archive/2026-06-10.md` (rotated 23:50).

**The arc.** A mid-run ~4h stall (15:01->19:02) exposed the never-stop hole at
the bitzer layer: shaun sat on a legitimate STANDBY but nothing poked bitzer, so
the sustain-poll never fired - autonomy duration failing at the layer meant to
enforce it. That triggered the day's spine: make the harness sustain itself, then
harden everything the sustain loop leans on.

**CLOSED this chapter (proof on origin before each close):**
- #9 - timmy's four state cues (spinner/menu/idle-box/question) made shape-based,
  pinned both directions; suite 16->28.
- #10 - those cues bottom-anchored so scrollback content cannot shadow a real
  state; suite ->36+. Exposed the idle-vs-working gap (-> #17).
- #13 - durable autonomous heartbeat: bin/heartbeat.sh raised by `barn.sh up` in
  a background window, no silent expiry, survives a bitzer restart. Replaced the
  session-cron stopgap.
- #14 - bitzer self-compaction baked into the prompt: shape-anchored pane-context
  detector + curated fail-closed self-compact.
- #16 - Farmer-directed context-hygiene policy, three layers: shirley compacted
  every slice, bitzer proactive self-compact + 80% ceiling, shaun
  STANDBY-after-hand. Dogfooded end to end.
- #17 - settled-idle suffix override (wide-pane) so a decoy spinner above an idle
  box reads idle; narrow-pane case is a documented residual under #8.
- #18 - Generality: launch configurability - configurable window name,
  collision-safe creation, pre-role-prompt injection hook. Safe to launch more
  than once on a host.
- #19 - Farmer-directed: usage gate skips on a positively-detected no-plan account
  (--plan-check), ambiguity falls to fail-open so an on-plan account is never
  mis-skipped.

**#8 (launch-verify) - structural verification COMPLETE, open as tracker.** Early
fixes: usage-gate x100 scaling (5216777), external-target .mossy/ git-exclude
escape (62970f1). Hermetic bin/barn.test.sh (31 green) covers target-mode path
resolution, the gitignore escape, and the up --plan layout. The one edge a chain
cannot self-verify (a live 3-pane target-mode boot) is escalated as a
Farmer-operated step (ESCALATIONS 23:43); the #17 narrow-pane, #19 API-only-creds,
and #18 deferred bits get checked during that boot.

## 2026-06-11 - Run 3 continued: timmy robustness, the wedge taxonomy, send-verified driving, event-driven Economy

Detail sealed in chapter `ticks/archive/2026-06-11.md` + `chronicle/archive/2026-06-11.md`
(rotated 2026-06-12 00:24). The chain relaunched this morning on the evolved prompts after
a 00:40 self-kill: case H's own EXIT trap ran `tmux kill-session` with an empty `-t`, which
resolves to the live session - the harness killed itself via its own new test. Both
Farmer fixes (trap guard + the `${session}:` HB-window target) rode in with #21.

## 2026-06-12 - Run 3 continued: the day-turn, and the engine holding for the Farmer

Live TICKS/CHRONICLE start fresh this chapter. The 2026-06-11 day-turn surfaced a genuine
bug and the engine worked it before settling back to the Farmer-gated hold:
- #39 - rotate.sh sealed the chapter under the wall-clock date, so a day-turn rotation (the
  common case) mislabelled the prior day's work under tomorrow. Fixed: explicit chapter-date
  arg (precedence) + infer-from-last-tick fallback, no-arg same-day default preserved; hermetic
  day-turn test. Found and fixed in operation, then dogfooded on the first real rotation (this
  06-11 seal used the explicit arg). Legibility + Robustness.

**The standing Farmer-gated hold (unchanged).** The in-chain frontier is exhausted; the two
high-value moves both need the Farmer: the #8 live target-mode boot (Generality) and the #36
relaunch-review (event-driven wake faithfulness already evidenced via live timmy --selftest).
One Farmer session activates both. bitzer holds, polling; no padding, act on the Farmer's word.

**CLOSED this chapter (proof on origin before each close):**
- #20 - sustain loop detects+recovers a stuck shaun turn (no STANDBY/spinner, pane
  stable across two heartbeat ticks), wired into bin/heartbeat.sh, hermetic.
  Autonomy + Safety.
- #21 - heartbeat-window collision-safety (the #18.2 residual): resolve_hb_window
  kills a stale orphan but never an innocent occupant; window raised at
  `${session}:`. Carried the 00:40 self-kill fix. Robustness.
- #22 - timmy recognises a narrow idle box whose footer WRAPS (the #17 residual).
  Robustness.
- #23 - timmy: persistent cross-snapshot motion overrules idle-box chrome, so a
  working decoy reads busy (the #22 residual). Robustness + Safety.
- #24 - per-role pre-boot injection: MOSSY_INJECT_<ROLE> env + --inject-<role> flag,
  across up AND relaunch (the #18.3 deferred follow-up). The cheap-worker /
  strong-driver Economy lever. Economy + Generality.

**The wedge taxonomy (banked, from driving the worker live).** Three distinct stall
classes, each its own recovery: SUBPROCESS wedge (frozen numeric counter + blocked
command, e.g. a bare git diff under the delta pager) -> C-c; MODEL-TURN / hung-suite
wedge (frozen spinner VERB + ps shows no process + no progress) -> Esc + re-hand;
ended idle prompt + no STANDBY -> plain wake (#20). The ps-process check is the
decisive real-vs-false discriminator: a 06:39 "wedge" was actually an unsent buffered
prompt (a long send-keys + immediate Enter raced) - so keep re-hands SHORT and VERIFY
submission (box empties + spinner starts) before calling a frozen pane a wedge.

**The stall-recovery arc (#25-#29, all CLOSED).** Driving the worker surfaced three
real wedges (hand-recovered) + a bitzer false alarm, then the chain mechanized the
supervision end to end: #25 timmy detects a frozen spinner as "stalled" (exit 40,
multi-sample confirm); #26 made the confirm timing env-overridable so the suite stays
fast (production byte-unchanged); #27 injects GIT_PAGER=cat into every pane + heartbeat
so no worker wedges on the host pager (Generality - any host); #28 stuck-check maps
stalled->stuck so a frozen driver triggers recovery; #29 the heartbeat alerts the driver
when the WORKER stalls (alert-only, disjoint from the driver path). Takes effect at the
next launch. Lesson banked: the pane elapsed counter is an unreliable liveness signal -
trust process activity + forward progress.

**Send-verified driving + event-driven Economy (#30-#36, all CLOSED) - the Economy milestone.**
- #30 - live-`up` preflight (claude/tmux/git on PATH, target is a git work tree) so the
  Farmer-operated #8 boot fails fast with one clear message. An #8 on-ramp. Generality + Robustness.
- #31 - bin/send-verified.sh: type + Enter, poll timmy, busy=submitted / idle=clear+retry-once-
  then-fail. Mechanizes the 06:39 prompt-submission lesson for a fresh shaun. Robustness (driving) + Economy.
- #32/#33 - send-verified adopted across every heartbeat send: the recovery wakes (#20 stuck +
  #29 worker-alert) and the bitzer sustain-trigger. No silent-delivery single point in the safety net.
- #34 - timmy --selftest: a human-readable #8-boot verdict over the same classify path (2nd #8
  on-ramp). Robustness + Generality.
- #35 - barn delivers boot ROLE prompts via send-verified (selective: role prompts only, inject
  lines stay plain) - the last unverified send. Verified delivery now complete across the harness. Robustness.
- #36 - MILESTONE: event-driven wake built end to end (4 slices). The heartbeat now wakes shaun on
  worker EVENTS (done / needs-input / stalled) + a STANDBY backstop after K idle beats; bitzer's
  blind every-beat STANDBY-wake is removed - the chain's biggest standing token cost. Judgment wakes
  on events, not the clock. The backstop net was built and proven BEFORE the blind-wake removal.
  Economy #2. Inert until next launch.

Banked (driving lessons): verify-submission must confirm a FRESH spinner (a prior turn's settled
glyph fools "a spinner"); rule out a BUFFERED input box (Esc reveals it) before calling a frozen
pane a wedge; when ps-checking the worker, exclude the chain's own heartbeat.sh (sleep 300) red
herring; the advancing pane counter is the reliable live signal.

**In flight:** #37 - parameterize the heartbeat suite's beat/confirm timing (the #26 lever applied
to heartbeat) so the grown ~73s suite runs fast. Economy + dev-loop legibility.

**Standing steering flag (for the Farmer) - sharper now.** With event-driven Economy done (#36) and
the send-verified / timmy hardening complete, the in-chain hermetic surface is worked down to modest
follow-ups (e.g. #37). The two highest-value frontiers left both need the Farmer: Generality - driving
a real external target - is gated on the live target-mode boot under #8 (a chain cannot self-verify a
nested live boot; #30 + #34 de-risk it). bitzer keeps the engine warm on the modest in-chain work, but
#8 is the high-leverage move and it awaits the Farmer's word.

**Open / parked / pending the Farmer:**
- #12 - close-vs-push: operational half landed (gate close on proving-commit-on-
  origin, 85e0607); binding GUARDRAILS-sequencing half escalated, Option A
  recommended (ESCALATIONS 19:09). An onorigin guard (0efb43e) exists but does not
  resolve the binding question. #11 (up-chain signals) is coupled and Farmer-blocked
  behind it.
- #15 - LaunchAgent heartbeat variant: parked `draft` pending the Farmer's
  mechanism call (vs #13's tmux window, which shaun reasoned against).
- #8 - launch-verify: structural verification COMPLETE; the live 3-pane target-mode
  boot is the Farmer-operated step (ESCALATIONS 23:43), the tracker for the #17
  narrow-pane, #19 API-only-creds, and #18 deferred residuals.

**Standing note.** Prompt and bin/ edits take effect only at the NEXT launch - a
running session keeps the prompts it booted with.
