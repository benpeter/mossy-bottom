# GUARDRAILS

> Writer: bitzer, and only bitzer, on the Farmer's word. Immutable from below:
> shirley and shaun never edit this file and never argue with it. shaun folds
> these invariants into the prompts he gives shirley.

Run 2 invariants - shirley is evolving the harness itself:

1. **Do not break the live run.** Never move, delete, or hand-edit the root state
   files (MISSION.md, GUARDRAILS.md, TICKS.md, CHRONICLE.md, ESCALATIONS.md). You
   may edit `bin/barn.sh` and `prompts/*.md` and add new files; those apply at the
   next launch, not live.
2. **Keep the default working.** A plain `barn.sh up` with no target must still
   raise a working chain after your changes. Never remove the ability to relaunch.
3. **Prove structurally, not with nested live chains.** shellcheck and `bash -n`
   clean; dry-run or unit-style checks for new barn.sh behavior; show new prompt
   steps are present and well-formed. Do not spawn nested live Claude chains to
   "test" - resource blowup, and it collides with this run.
4. **Vanilla only.** No new dependencies without the Farmer's allowance (`gh` is
   already present and allowed).
5. **Proof required; never claim done.** Every accepted change is backed by visible
   proof in your pane (shellcheck output, a dry-run, a diff). Report what you proved
   and what is next.
6. **Conventional Commits**, subjects speak to the diff. Stage only the files your
   slice changes; never `git add -A` - the root run-state files must never be swept
   into your commits (those are bitzer's).
7. **Hygiene.** shellcheck-clean; no secrets or private data; English; ASCII
   diagrams; no em or en dashes - use " - ".
8. **Direction is shaun's.** Report proof and blockers; shaun picks the next slice
   from the issues.
