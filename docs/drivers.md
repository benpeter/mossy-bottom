# Drivers: running a role on something other than Claude Code

One harness, any driver at any level. A "driver" is the coding agent a role
runs. Every role defaults to Claude Code, so an existing chain is unaffected;
`bin/barn.sh up --plan` is byte-identical before and after this was introduced.

This replaces the `mossy-copilot` fork, which existed from 2026-07-27 to
2026-07-28 to find out what actually differs between the two TUIs. The fork was
the right way to find out and the wrong way to keep it: within one night, two of
six escalations were harness defects that existed only because the fork forked.
A window-sizing bug with nothing to do with Copilot was fixed in one repo and not
the other, and a timmy regression landed on the fork while upstream stayed
correct.

## Configuration

Three per-role variables, all mirroring the `MOSSY_INJECT_<ROLE>` seam. ROLE is
`BITZER`, `SHAUN` or `SHIRLEY`.

| variable | values | default |
|---|---|---|
| `MOSSY_DRIVER_<ROLE>` | `claude`, `copilot` | `claude` |
| `MOSSY_MODEL_<ROLE>` | any model the driver offers | `opus` / `gpt-5.6-sol` |
| `MOSSY_BOUNDARY_<ROLE>` | `compact`, `fresh` | `compact` |

A cheap worker under two Claude drivers, which is the configuration that ran the
first live Copilot night:

    MOSSY_DRIVER_SHIRLEY=copilot bin/barn.sh up ~/dev/some-target

An unrecognised value falls back to the default rather than failing, in both
directions that matter: an unknown driver is `claude`, and an unknown boundary is
`compact`. Silently discarding a driver's context is the expensive way to be
wrong.

`up --plan` lists a role only when its driver or model differs from the default,
so an all-claude plan stays byte-stable while a mixed chain is previewable.

Preflight asks for a driver's binary only when a role selects that driver. A host
without `copilot` still raises an all-claude chain.

## Verified live

Booted 2026-07-28 against a throwaway target, in its own tmux session, with
`MOSSY_DRIVER_SHIRLEY=copilot`:

- All three panes reached their input box with no warning, so the Copilot ready
  marker and its two-key trust gate both work. A wrong marker here does not fail
  loudly: `boot_pane` waits out its whole timeout and leaves a pane running
  without its role.
- bitzer and shaun came up on Claude Code (Opus 5), shirley on Copilot CLI
  (GPT-5.6 Sol), and shirley correctly received no prompt.
- timmy classified all three with no configuration: the two Claude panes busy on
  their role prompts, the Copilot pane idle at its prompt.
- The two prompt selectors resolved independently in shaun's boot string:
  `prompts/drivers/claude.md` for the agent he runs, `prompts/workers/copilot.md`
  for the pane he watches.

## Models are gated by org policy

Do not hardcode a model name. Which models exist depends on the GitHub org, and
they differ from what the docs suggest. Probed on this machine, 2026-07-28,
against Copilot CLI 1.0.75 on an Adobe EMU account:

| model | available |
|---|---|
| `claude-opus-4.8` | yes |
| `claude-sonnet-5` | yes |
| `claude-sonnet-4.5` | yes |
| `gpt-5.6-sol` | yes |
| `claude-opus-5` | **no** |

An earlier version of this document claimed `claude-opus-5` was available through
Copilot. That was read off a model list rather than probed, and it was wrong. To
check a model, run `copilot -p OK --model <name>`: an unavailable one fails
immediately with `Model "<name>" ... is not available` and costs nothing.

`--yolo` and `--allow-all` are the same flag. Both expand to `--allow-all-tools
--allow-all-paths --allow-all-urls`. Leave `--no-ask-user` OFF: answering the
worker's questions is what the layer above it is for, and disabling the ask tool
removes the thing the chain exists to do.

## Why the classifier needs no configuration

timmy classifies either TUI with no flag, and this is the property that makes one
harness work rather than two.

Its core is a double-snapshot diff, which never cared what runs in the pane.
Everything above that is cue detection, and cues are additive: `has_spinner` for
Claude Code, `has_worker_spinner` for Copilot, ORed together. A third driver adds
a third function and one more `||`.

**Resist any design that passes a `--driver` flag into timmy.** If a cue needs to
know which driver it is looking at, the cue is not anchored tightly enough.

## The prompt files

Two independent selectors, because a role's own agent and the pane it watches are
different questions. A Copilot-driven shaun watching a Claude Code worker reads
`drivers/copilot.md` for himself and `workers/claude.md` for her.

| file | describes | selected by |
|---|---|---|
| `prompts/workers/<driver>.md` | the pane shaun WATCHES | shirley's driver |
| `prompts/drivers/<driver>.md` | the agent the role RUNS | that role's own driver |

`workers/` is a clean split: `shaun.md` never held worker dialect, so it stays
driver-agnostic and a test enforces that.

`drivers/` is an override, not a split. The Claude Code machinery in `bitzer.md`
and `shaun.md` is woven through 600 lines of live procedure, so the dialect file
states which passages still apply and what replaces the ones that do not.
Extracting it properly is a later change with its own risk.

## What Copilot does differently

Learned live on 2026-07-27, in a royalairmaroc.com migration with Copilot in the
worker seat.

**The busy cue is BELOW the box.** Copilot keeps its composer rendered for the
whole turn and changes only the footer; Claude Code puts its spinner above the
box. Looking upward finds nothing, so a busy worker reads idle. That one
difference caused two separate false-idle defects.

**The word `Working` is not reliable.** Copilot swaps the current task name in
where it would be, so `◉ Committing failing header test · 8.9 KiB esc interrupt`
is a normal busy footer. Key on the interrupt affordance. That is safe only
because the match is position-anchored below the last rule-fenced box, and there
is a fixture asserting a transcript quoting the phrase does not fire it.

**Never fall back to motion.** Before the cue was fixed, the verdict came from
`sustained_motion`, which was decided by whether two snapshots happened to land
on the same frame of an alternating `◉`/`◎` glyph. Same worker state, two
different answers. A coin flip wearing the clothes of a measurement, and worse
than a consistent bug because it hides.

**`●` not `⏺` for an assistant turn.** Match the two as **two anchored
alternatives, never a bracket class**: awk matches a bracket expression byte-wise,
so `[⏺●]` also matches every other U+2xxx glyph in the pane, box rules included,
and the turn marker lands on chrome. That ate all 13 question tests in the fork.

**A slash command needs TWO Enters.** Typing `/` opens a filter palette; the
first Enter picks the highlighted entry out of it and the second submits. One
Enter leaves the command in the composer, which reads exactly like a send that
silently failed. `bin/send-verified.sh` handles this: it sends the second Enter
only when the pane speaks Copilot AND the text is a slash command, so a Claude
Code pane never gets a stray Enter that would start an empty turn.

**`/compact` takes no focus string**, so the keep-strings in the role prompts do
nothing and the role has to re-anchor by hand afterwards.

**There is no context meter.** The status line counts AI credits as `Session: N
AIC used`, so any rule keyed on `Context: N%` has nothing to read. Use slice
boundaries instead, and do not invent a proxy percentage.

**The credit counter is not cumulative.** It has been observed to DECREASE across
consecutive reads, going 2677, then 2504, then 2538. Treat it as directional and
never quote it to the digit. The cost figures below inherit that caveat.

**Skills load once, at session start, and register by frontmatter `name:`, not by
directory.** A skill added mid-run is invisible until a relaunch. Symlinking a
skill under a prefixed directory name does not rename it. Those two facts masked
each other for two hours on the first run: the session predated the symlinks, and
the names would not have resolved anyway.

**The two drivers disagree about what a skill is called, off the same directory.**
Claude Code lists a skill by its DIRECTORY; Copilot registers it by the
frontmatter `name:`. On this machine's shared `~/.claude/skills`, 19 of 34
migration skills differ between the two, and three register under prose titles
with spaces:

| directory | Claude Code calls it | Copilot calls it |
|---|---|---|
| `eds-page-import` | `eds-page-import` | `page-import` |
| `eds-docs-search` | `eds-docs-search` | `Searching-AEM-Documentation` |
| `eds-content-driven-development` | `eds-content-driven-development` | `Using-Content-Driven-Development` |

Note the second transformation: Copilot also replaces SPACES WITH HYPHENS, so a
frontmatter `name: Searching AEM Documentation` resolves as
`Searching-AEM-Documentation`. Reading the frontmatter alone is not enough, and
that mistake was made and caught here: a roster built from raw frontmatter listed
three names that did not resolve, and the worker found it on her first
post-relaunch check.

So a driver that names a skill for its worker must use the name the WORKER's
driver resolves, not the one it sees itself. Getting this wrong looks exactly
like a failed relaunch: the worker reports the skill missing and both sides are
reading a real directory. Generate the mapping and hand over the resolved column
rather than assuming they agree.

**Commits get a `Co-authored-by: Copilot` trailer**, built in the commit command
with no setting to disable it. If a project bans tool attribution, say so in the
guardrails and check before the first push, because removing it afterwards is a
history rewrite.

## Cost

Order of magnitude only, at `gpt-5.6-sol` and `xhigh`, subject to the
non-cumulative counter above.

| work | AI credits |
|---|---|
| trivial one-line reply | ~9 |
| small shell task | ~15 |
| reading a 157-line guardrails file | ~20 |
| a full measure-and-report slice | 60 to 120 |

Roughly 400 credits an hour in steady state.

## What needed no changes

The interesting result is how little differs. The deference chain, the trust
rule, the evidence rule, `heartbeat.sh`, `stuck-check.sh`, `rotate.sh` and
timmy's core detector all worked unchanged. The architecture was driver-agnostic
already.

Copilot held strict TDD across nine commits without being reminded, produced a
header matching the live site on every measured box, and reported every blocker
it hit instead of working around it: it refused to patch the measurement tool,
refused to rewrite history, and refused to hand back a measurement it could not
take.

## The open question

Nobody has tried a cheap DRIVER. The value of the first live night came from the
driver layer, not the worker: all six escalations were the driver watching the
worker. If that holds, the interesting configuration is a cheap worker under an
expensive driver, which is what ran. The merged harness makes the opposite
experiment one variable to change.
