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
- **Frontier #13 (durable autonomous heartbeat) - in progress.** Replaces the
  session-cron stopgap with a harness-native heartbeat raised by `barn.sh up`,
  no silent expiry, survives restarts. Slice A (standalone timmy-gated trigger,
  bin/heartbeat.sh) landed (64ca23f); Slice B (barn.sh up wiring) in flight.

Detail for all of the above lives in the live CHRONICLE.md and TICKS.md dated
2026-06-10 (no rotation has occurred yet, so there is no dated archive chapter).
