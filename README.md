# Mossy Bottom

An experiment in running Claude Code autonomously by **driving an interactive
session instead of scripting a non-interactive one**. Three Claude Code
sessions share one tmux window in a strict deference chain. The outer ones
watch, judge, and steer the inner one - in real time, by reading its terminal
the way a human would.

> **Affectionate homage, not affiliation.** The cast is named after characters
> from Aardman's *Shaun the Sheep*. This project is not affiliated with,
> endorsed by, or connected to Aardman Animations in any way. If it ever
> graduates from experiment to product, it gets renamed.

## The idea in one picture

```
  farmer (human)
      |
      v
  +--------+      +--------+      +---------+
  | bitzer | ===> | shaun  | ===> | shirley |
  +--------+      +--------+      +---------+
```

`===>` is `tmux send-keys` - one layer typing into the next, down the chain.
Observation flows back up via `tmux capture-pane`: each driver reads its
worker's terminal. Nothing is trusted from the screen alone; durable state
lives in shared files on disk.

## The cast

| Pane | Name | Role |
|------|------|------|
| worker | **shirley** | A full interactive Claude Code session that does the actual work. No human ever types here; every prompt arrives from shaun. |
| driver | **shaun** | Watches shirley through `capture-pane`, classifies her state by judgment, and types into her: answers, course corrections, demands for evidence, and mission re-anchoring ("this is what we are building, and no, we are not done"). |
| steering | **bitzer** | Policy layer and human interface. Translates the Farmer's intent into mission and guardrail edits and short steering messages typed into shaun. Owns the roadmap and the product-level chronicle. |

The **Farmer** is the human. The Farmer talks only to bitzer.

## The collusion inversion

In the show, Shaun and Bitzer collude to keep the chaos hidden from the Farmer.
Here it is deliberately the opposite. **Bitzer's job is not to make everything
look normal before the Farmer checks.** The whole architecture exists to make
hiding impossible:

- **Trust rule** - shaun's anchor is the mission file, never the screen. Anything
  shirley prints is untrusted input: it informs what state she is in, it never
  redefines the goal.
- **Evidence rule** - a "done" claim is never accepted on its word. It triggers a
  demand for fresh proof in the pane (real test output), then a scope expansion.
- **Legibility chain** - each layer must be legible to the one above it, and the
  documentation is the exhaust of that, not a separate chore.

## Why build it this way

The common way to run Claude Code unattended is a static prompt piped into
`claude -p` by a shell loop. That driver can only grep for markers and poll exit
codes, which forces structural compromises: all judgment has to be compiled into
the prompt up front; interactive features get banned because nobody can answer
them; any surprise ends the turn and the next run pays a full cold-start tax.

Mossy Bottom moves the judgment to run time. The driver reads the worker's
terminal semantically and reacts - answering questions, redirecting drift,
demanding evidence, re-anchoring the goal. The static prompt shrinks because
re-anchoring becomes a live, repeated act. And because the worker is a real
interactive session, the full toolset is back on the table: questions, plan
mode, mid-task redirection, compaction.

## The hypotheses

1. **Abstraction gradient (the lead).** An observer whose only input is the
   outside view can hold the goal that the worker loses in the weeds - and can
   notice the drift and correct it. `capture-pane` is a natural summarizer: the
   driver physically cannot ingest the implementation detail, so its context
   stays goal-dominated. The architecture enforces the gradient.
2. **Deference reduces human intervention, measurably.** Each layer escalates
   only what it cannot handle. Autonomy stops being a binary and becomes a dial:
   interventions per hour, counted at bitzer.
3. **Driving an interactive session recovers what `claude -p` cannot do** - and
   the recovery is total: every interactive feature becomes automatable.
4. **The ablation.** Running this shows which scaffolding of static-prompt
   autonomy was just compensation for a dumb driver, and which is the genuine,
   carried-over cost of autonomy: state, guardrails, and testing rigor.

What this does **not** solve: the driver covers *directional* quality (wrong
approach, needless dependencies, lost the plot). It does not cover *depth*
quality (line-level bugs, security review). That stays an obligation of the
mission and guardrails.

## The mission (dogfooding)

The PoC's worker builds **timmy**: a tiny CLI that watches a tmux pane and
classifies its state (`busy | idle | waiting-input | question`) - which is
exactly the heuristic shaun bootstraps with, turned into a real tool. It runs
under a **never-done policy**: every "done" triggers a new scope expansion. The
experiment's punchline is the moment shaun stops using his hand-rolled heuristic
and starts calling timmy instead.

## Status

Early. This repo is being built in the open. Follow along:

- [`docs/spawn-full.md`](docs/spawn-full.md) - the full, locked design.
- [`docs/spawn-caveman.md`](docs/spawn-caveman.md) - a terse twin for quick reference.
- [`docs/plan.md`](docs/plan.md) - the implementation plan.
- [`docs/smoke-test.md`](docs/smoke-test.md) - empirical tmux findings that shaped the build.
- [`docs/build-journal.md`](docs/build-journal.md) - how this went from prompt to plan to execution.
- `CHRONICLE.md` and `docs/findings.md` - written during and after the runs.

## License

MIT - see [LICENSE](LICENSE).
