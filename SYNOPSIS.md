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

**Open / parked / pending the Farmer:**
- #12 - close-vs-push: operational half landed (gate close on proving-commit-on-
  origin, 85e0607); binding GUARDRAILS-sequencing half escalated, Option A
  recommended (ESCALATIONS 19:09). #11 (up-chain signals) is coupled and
  Farmer-blocked behind it.
- #15 - LaunchAgent heartbeat variant: parked `draft` pending the Farmer's
  mechanism call (vs #13's tmux window, which shaun reasoned against).
- #20 - sustain loop should structurally detect+recover a stuck shaun turn (no
  STANDBY, no spinner, pane stable across two ticks); seen twice this chapter,
  recovered each time by a bitzer nudge.
- #21 - heartbeat-window collision-safety (the #18.2 residual); the next workable
  structural frontier.

**Standing note.** Prompt edits (#16, #19, and any bin/ edits) take effect only at
the NEXT launch - this session still runs the booted prompts.
