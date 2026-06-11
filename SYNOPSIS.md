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

## 2026-06-11 - Run 3 continued: timmy robustness, Economy levers, the wedge taxonomy

Detail in the live TICKS/CHRONICLE (seals to chapter `2026-06-11.md` at the next
rotation). The chain relaunched this morning on the evolved prompts after a 00:40
self-kill: case H's own EXIT trap ran `tmux kill-session` with an empty `-t`, which
resolves to the live session - the harness killed itself via its own new test. Both
Farmer fixes (trap guard + the `${session}:` HB-window target) rode in with #21.

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

**In flight:** #25 - timmy classifies a frozen spinner (wedged turn) as stalled (new
exit 40), not plain busy - moving the manual wedge-check into the dumb tool. Economy +
Robustness.

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
