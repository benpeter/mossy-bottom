# SYNOPSIS

The milestone arc of Mossy Bottom - a bounded index over the dated archives, not
a transcript. Maintained by bitzer at each rotation and each milestone. The
rehydration entry point: a fresh shaun rehydrates from this plus the most recent
chapter, never the whole archive.

Each entry: date (from `date`, never guessed), what landed, what was proved, and
which chapter holds the detail.

---

## 2026-06-10 - Run 3: self-evolving harness (engine + steering overlay)

- **Frontier #9 (timmy classifier robustness) - CLOSED.** All four of timmy's
  state cues (spinner, menu, idle-box, question) hardened from content-matching
  to shape-based and pinned in both directions; hermetic suite grew 16 -> 28.
  Two defects were caught live by the running chain. Commits 05b09ae, c08421d,
  f476c95. Detail: live CHRONICLE/TICKS (2026-06-10).
- **Frontier #8 (launch-verify) - landed substantially, kept open as tracker.**
  First live boot caught and fixed two launch defects: usage-gate x100 scaling
  (5216777) and external-target .mossy/ git-exclude escape (62970f1); target-mode
  path resolution verified; mechanism documented (640c381).
- **The never-stop hole - found and fixed at the bitzer layer.** Run stalled ~4h
  (15:01 -> 19:02): shaun ended on a legitimate STANDBY but nothing poked
  bitzer's pane, so the sustain-poll never fired - autonomy duration failing at
  the layer meant to enforce it. Stopgap: a durable heartbeat cron firing every
  5 min while bitzer is idle (wake/queue/push/rotate + self-compact). Lasting
  fix filed as frontiers #13 and #14. Detail: CHRONICLE 2026-06-10 19:09.
- **Frontier #12 (close-vs-push alignment) - operational half landed.** Issue
  could read CLOSED while its proving commit was still local-only. Operational
  fix: gate issue-close on the proving commit being on origin (85e0607). The
  binding-invariant half is escalated to the Farmer (GUARDRAILS sequencing),
  pending decision (ESCALATIONS 2026-06-10 19:09).
- **Frontier #13 (durable autonomous heartbeat) - CLOSED.** Replaced the
  session-cron stopgap with a harness-native heartbeat: standalone timmy-gated
  trigger bin/heartbeat.sh (64ca23f) raised by `barn.sh up` in a background
  window (741aaa7), no silent expiry, survives a bitzer REPL restart. Proven
  launch-free via --plan.
- **Frontier #14 (bitzer self-compaction) - CLOSED.** Bakes the self-compact
  stopgap into the prompt: position/shape-anchored pane-context detector
  (970990e) plus a curated self-compact wired into bitzer.md, gated on that
  detector and fail-closed (c5af4b3). A future bitzer inherits it at next launch.
- **Frontier #15 (LaunchAgent heartbeat variant) - PARKED (draft).** Farmer-filed
  alternative mechanism (OS-level LaunchAgent vs #13's tmux window, which shaun
  reasoned against). Held as `draft` pending the Farmer's mechanism call.
- **Frontier #10 (position-anchor timmy's cues) - CLOSED.** All four cues
  bottom-anchored so scrollback content cannot shadow a real state: spinner
  (structural prompt-anchor replacing fragile K=6: a97ba1d, d3643bd), idle-box
  (0dc302e), menu (31c154e), question + footer-chrome hardening (9fafbe2).
  Hermetic suite grew through 36+ fixtures. A deferred residual (idle box vs
  working input box are not yet discriminated) was filed as frontier #17.
- **Frontier #17 (idle-vs-working discrimination) - open.** timmy cannot yet
  tell a settled idle box from a working input box; the #10 anchoring exposed it.
- **Frontier #16 (context-hygiene policy) - COMPLETE (close pending).** Farmer-
  directed, built in three layers and dogfooded end to end: shirley compacted at
  every slice boundary, threshold demoted to backstop (5ee5cd2); bitzer proactive
  self-compact at concern boundaries + 80% hard ceiling (137aa18); shaun
  between-slice self-compaction via STANDBY-after-hand (41afa7f). Lands for the
  whole chain at next launch (prompt edits are next-launch per inv.1). Close
  deferred to a fresh shaun now that the proving commits are on origin.

Detail for all of the above lives in the live CHRONICLE.md and TICKS.md dated
2026-06-10 (no rotation has occurred yet, so there is no dated archive chapter).
