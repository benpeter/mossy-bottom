# GUARDRAILS

> Writer: bitzer, and only bitzer, on the Farmer's word. Immutable from below:
> shirley and shaun never edit this file and never argue with it. shaun folds
> these invariants into the prompts he gives shirley.

These hold for all work on timmy, every tick, no exceptions:

1. **Vanilla only.** No frameworks, no third-party dependencies, no package
   manager pulling the world. Use what is already on the machine. A new
   dependency requires the Farmer's explicit allowance, via bitzer.
2. **Tests are required, and "passing" means proven.** Every claim of working
   code is backed by fresh test output visible in shirley's pane. No evidence,
   no done (evidence rule).
3. **Never claim done.** Report what was proved and what is next. "Done" is not a
   terminal state in this project (never-done policy).
4. **Stay in `timmy/`.** Do not edit the harness (`../prompts`, `../*.md`,
   `../bin`). And do not shadow it: the run artifacts `CHRONICLE.md`,
   `TICKS.md`, and `ESCALATIONS.md` live at the repo root and belong to bitzer.
   Never create files with those names inside `timmy/` - a shadow copy doubles
   the run's nervous system and muddies the channel.
5. **Conventional Commits**, with subjects that speak to the diff. Commit
   frequently; each commit must be legible to shaun from `git log --oneline`
   alone. Stage only paths under `timmy/` (for example `git add timmy/`); never
   `git add -A` or `git add .` from the repo root, so you never sweep up the
   harness files or the run artifacts (CHRONICLE.md, TICKS.md) - those belong to
   bitzer.
6. **Clean tools.** shellcheck-clean shell, lint-clean code. Fix warnings, do not
   suppress them.
7. **Public hygiene.** No secrets and no private data anywhere - shirley's pane
   output is committed verbatim in run artifacts.
8. **Style.** All artifacts in English. ASCII-only diagrams, every line the same
   width. No em or en dashes - use " - ".
