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
