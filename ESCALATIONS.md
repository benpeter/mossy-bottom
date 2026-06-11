# ESCALATIONS

Things shaun cannot resolve from MISSION + GUARDRAILS, raised for bitzer (and
through bitzer, the Farmer). shaun writes; bitzer reads.

Entry format:

```
## HH:MM - <one-line summary>
- What happened:
- Why shaun cannot resolve it (what policy or fact is missing):
- What is needed to unblock:
```

---

## 19:09 - #12: make the close-after-push ordering a binding GUARDRAILS invariant
- What happened: Farmer filed #12 ("are push-responsibility and issue-close
  responsibility at the same level?"). shirley's report-first audit, which I
  independently verified against the files, confirms a real divergence: shaun
  closes an issue (shaun.md:158-161) the moment a slice is accepted, with NO
  check that the proving commit is on origin; bitzer is the sole pusher
  (bitzer.md:119-125) and pushes on his own sustaining-poll cadence. So an issue
  can read CLOSED while its proving commit is still local-only - the public
  record (closed issue) diverges from the upstream proven state until bitzer's
  next push. bitzer.md:64-65 reopen-if-premature is a backstop, not
  synchronization. I have directed the operational fix (a precondition in
  prompts/shaun.md: confirm the commit is on origin before close, else defer the
  close) - shirley is building it now.
- Why shaun cannot resolve it: the operational shaun.md precondition closes the
  routine window, but making it BINDING (an invariant that holds across
  relaunches and cannot be dropped by a future prompt rewrite) means a new
  GUARDRAILS invariant. GUARDRAILS is bitzer's, immutable from below - I cannot
  write it. This also touches the chain's authority model (who owns close vs
  push), which is bitzer/Farmer territory, and #12 is Farmer-filed.
- What is needed to unblock: bitzer's decision on whether to add a sequencing
  invariant to GUARDRAILS, e.g. "An issue is closed only after its proving
  commit is on origin; if a close is later found to precede its push, reopen."
  My recommended direction is Option A (sequence close after push, preserve the
  single-pusher invariant - smallest change). Options B (move close up to bitzer,
  co-located with push) and E (self-healing reopen on post-close push failure)
  are in shirley's audit if you prefer a different shape. Note the overlap with
  #11 (event-driven up-chain signals): Option B would also seed #11's
  shaun->bitzer "ready to close" signal.

## 23:43 - #8: the live target-mode boot needs a Farmer-operated launch
- What happened: #8's launch-free verification is now COMPLETE and on origin.
  Dogfood mode is dogfooded by this running chain itself (it booted and drove
  #16/#17/#19/#18 end to end). Target mode is fully covered by a new hermetic
  suite (bin/barn.test.sh, 31 green): resolution to absolute paths, the .mossy/
  gitignore escape (seed_target_exclude with idempotency + both skip cases), and
  the up --plan path/env layout (STATE_DIR/REPO_DIR/panes + per-pane cwds, with a
  dogfood contrast). The one edge no launch-free test can reach is the actual
  live target-mode boot: real claude in three real panes against an external
  scratch repo, the chain driving one real slice there.
- Why shaun cannot resolve it: a full target-mode boot is a three-pane chain.
  Launching it from inside the running chain is a nested live chain - forbidden by
  the opening directive ("never launch nested live chains") and inv.1 ("never
  break the live run"). inv.3 sanctions ONE throwaway verification pane, not a
  whole second chain. So the chain structurally cannot self-verify a live boot.
- What is needed to unblock: the Farmer (or bitzer, out-of-band) runs
  `bin/barn.sh up <scratch-target-repo>` on a host, confirms the evolved prompts
  boot and $MOSSY_STATE_DIR/$MOSSY_REPO_DIR resolve in every pane, and the chain
  drives one real slice in the target; then reports back. The residuals parked
  under #8 get checked during that boot: the #19 API-only creds shape (no-plan
  gate-skip against a real keys-only account), the #17 narrow-pane idle case, and
  #18's two deferred bits (per-role MOSSY_INJECT_<ROLE> variants and the
  heartbeat-window 'index in use' collision). #8 stays open as the tracker for
  this Farmer-operated step. Meanwhile the chain keeps working the structural
  frontier filed alongside this (heartbeat-window collision-safety).

## 2026-06-11 08:28 - The hermetic hardening frontier is worked down; recommend prioritizing the #8 live boot

- What happened: across this run the chain closed a long hardening arc - #22/#23/#25 (timmy
  classification robustness incl frozen-spinner stall detection), #24 (per-role inject),
  #26 (fast timmy suite), #27 (pager-safe launch), #28+#29 (the stall-recovery loop:
  detect -> map -> recover-shaun -> alert-on-worker), #30 (live-up preflight). timmy, the
  recovery loop, and the launch path are now well-hardened and hermetically tested.
- The situation: the highest-VALUE remaining quality is Generality #5 - actually driving a
  real external target, several side by side - and its substantive work routes through the
  one step the chain structurally cannot do to itself: the live 3-pane target-mode boot
  (#8, Farmer-operated, ESCALATIONS 23:43). #30 just de-risked that boot (it now fails fast
  with clear diagnostics on a fresh host). Remaining IN-CHAIN frontiers are
  diminishing-return hardening (e.g. #31 send-verified, the driving-side analog of the
  classification work - genuine but modest).
- Why shaun raises it: not a blocker and not a stop (the engine keeps running; #31 is handed
  to keep the queue non-empty). This is a STEERING flag for the Farmer to weigh: prioritize
  the #8 live target-mode boot to unlock the Generality tranche, vs let the chain continue
  modest hardening. The chain cannot self-run #8 (nested live chain forbidden, inv.1).
- What would unblock the big tranche: the Farmer (or bitzer, out-of-band) runs
  `bin/barn.sh up <scratch-target-repo>` on a host and drives one real slice there - now
  with #30's preflight catching a misconfigured host up front. The #8 residuals (#19
  API-only creds, #18 deferred bits) get checked during that boot.
