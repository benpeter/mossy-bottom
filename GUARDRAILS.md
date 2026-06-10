# GUARDRAILS

> Writer: bitzer, and only bitzer, on the Farmer's word. Immutable from below:
> shirley and shaun never edit this file and never argue with it. shaun folds
> these invariants into the prompts he gives shirley.

Standing invariants for the self-evolving harness:

1. **Never break the live run.** The root state files (MISSION.md, GUARDRAILS.md,
   TICKS.md, CHRONICLE.md, ESCALATIONS.md, SYNOPSIS.md) are never moved, deleted,
   or hand-edited by shirley. Edits to `bin/` and `prompts/` apply at the next
   launch, never to the running chain.
2. **Stay relaunchable.** A plain `bin/barn.sh up` must raise a working chain
   after every change.
3. **Proof is structural by default.** shellcheck and `bash -n` clean; hermetic
   tests; barn.sh proven via its launch-free `--plan` mode. Live Claude sessions
   for verification only when the issue being worked explicitly calls for it -
   one at a time, in a throwaway pane outside the chain's window, torn down
   afterward.
4. **Vanilla only.** No new runtime dependency without the Farmer's allowance
   (`tmux`, `git`, `gh`, `jq` are present and allowed).
5. **Evidence, never "done".** Every claim is backed by fresh visible output in
   the pane. Accepting a proven slice triggers close-and-spawn
   (prompts/shaun.md), never a stop.
6. **Git discipline.** Conventional Commits, subjects speak to the diff. Stage
   only the files your slice touched - never `git add -A`. The root run
   artifacts are bitzer's to commit, and bitzer is the sole pusher.
7. **Public hygiene.** No secrets or private data anywhere - pane output gets
   committed verbatim in run artifacts.
8. **Style.** English; ASCII-only diagrams, every line the same width; no em or
   en dashes - use " - ".
9. **Direction is shaun's, within the MISSION vision.** shirley reports proof
   and blockers; she does not pick the next slice. Frontiers outside the vision
   need a Farmer-filed issue or an escalation.
