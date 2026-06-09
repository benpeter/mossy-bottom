# Harness / target split (Issue #2)

Mossy Bottom is a generic control plane. It drives an external target project rather
than only itself. This documents what shipped, not what might.

## Control plane vs target

- **Control plane** - this repo: `bin/barn.sh` and `prompts/*.md`. These are assets
  of the harness. They never move into a target. A role is always pointed at its
  prompt by the control-plane repo path (`<repo>/prompts/<role>.md`).
- **Target** - the project the chain works on. With `bin/barn.sh up <target>` the
  three panes (bitzer, shaun, shirley) run with their cwd set to the target. With no
  target, the harness drives itself (dogfood) and the panes run in the repo root.

## Per-run state lives in `<target>/.mossy`

Each run's state files - `MISSION.md`, `GUARDRAILS.md`, `TICKS.md`, `CHRONICLE.md`,
`ESCALATIONS.md`, and the runtime `.barn-panes` - live in the target's `.mossy`
directory. barn resolves that directory to an absolute path and writes it by absolute
path, so a pane finds its state regardless of cwd. barn injects `MOSSY_STATE_DIR`
(the absolute state dir) into every pane's environment, and the role prompts read and
write each state file as `${MOSSY_STATE_DIR}/<file>`.

In the dogfood case `MOSSY_STATE_DIR` is the repo root, where the run record already
lives, so every `${MOSSY_STATE_DIR}/<file>` resolves to exactly the same file as
before. The split is real for an external target and a no-op for dogfood.

## Ownership by area

The deference chain owns the repo by area; the boundaries are what keep the gradient
from collapsing into "everyone edits everything".

- **shirley** owns the work - the target's source and tests. She never touches
  `.mossy/`. The run's state is not hers to write.
- **bitzer** owns `.mossy/`. He authors `MISSION.md` and `GUARDRAILS.md` there, only
  on the Farmer's word, and writes the product-level `CHRONICLE.md`. The Farmer files
  GitHub issues as the work-queue; bitzer triages them.
- **shaun** reads `.mossy/` (MISSION, GUARDRAILS) and `git log`, plus shirley's pane
  and the open non-draft issues. He never reads shirley's source - that is the diet
  rule. He writes `TICKS.md` and his own `CHRONICLE.md` entries, and escalates to
  `ESCALATIONS.md`.

## Preflight contract

`bin/barn.sh up <target>` refuses to spawn unless the resolved state dir already holds
Farmer-authored `MISSION.md` and `GUARDRAILS.md`. barn never fabricates or templates
them - a machine-stubbed mission is exactly the failure Mossy Bottom exists to avoid.
If either is missing, barn names what is missing, says the Farmer/bitzer must author
them there first, and exits non-zero having spawned nothing and created nothing (the
check runs before any `mkdir`, so an unauthored target gets no stray `.mossy`).

`bin/barn.sh up --plan [<target>]` prints the spawn plan - pane cwds, injected
`MOSSY_STATE_DIR`, panes-file path - plus a non-blocking preflight readiness line. It
launches nothing, so it is safe to inspect a target before its state is authored.

## The `.mossy/` gitignore escape hatch

`.mossy/` is gitignored so a target project keeps a clean history - the harness's
per-run bookkeeping does not show up in the target's commits. The pattern matches any
`.mossy/` at any depth, including test targets nested inside this repo. The dogfood run
record lives at the repo ROOT, not under `.mossy/`, so it stays tracked.
