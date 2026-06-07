# Mossy Bottom - Smoke Test Findings

Empirical facts established before building anything, per the spawn doc's
"empirical smoke test before building anything." These facts shape `bin/barn.sh`
and `prompts/shaun.md`. Run on 2026-06-07 against a scratch interactive Claude
Code session driven by tmux `send-keys` / `capture-pane` - exactly how shaun
will drive shirley.

**Environment.** tmux 3.6a, Claude Code 2.1.168 (binary at
`/Users/bp/.local/bin/claude`), default model Opus 4.8, launched with
`--dangerously-skip-permissions` in a detached tmux window. The pane was targeted
by its immutable pane id (e.g. `%2`), never by index.

**On the captured-output blocks below.** They are VERBATIM terminal glyphs. The
Claude Code TUI uses Unicode box-drawing and symbols, and shaun and timmy must
recognize these exact glyphs, so they are reproduced as-is rather than
ASCII-fied. They are data, not hand-drawn diagrams. Personal account and welcome
lines from the boot splash are omitted for public hygiene.

## 1. Boot has a trust-folder gate - even with skip-permissions

A first launch in a not-yet-trusted directory shows a blocking prompt BEFORE the
input box, even with `--dangerously-skip-permissions`:

```
 Quick safety check: Is this a project you created or one you trust? ...
 ❯ 1. Yes, I trust this folder
   2. No, exit
 Enter to confirm · Esc to cancel
```

Option 1 is preselected; a single `Enter` accepts. Timing observed: roughly 8s
from launch to this prompt, roughly 6s from accept to the idle box (about 15s
total to boot).

Implication: barn.sh must, per pane, (a) wait for and accept the trust gate
(send `Enter`), then (b) wait for the idle input box, before sending any role
prompt. This applies to all three panes on first launch in their cwd.

## 2. Idle input box signature

A settled, idle session looks like this at the bottom of the pane:

```
────────────────────────────────────────────────
❯
────────────────────────────────────────────────
  <cwd> | Opus 4.8 (1M context) | Context: 5%
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
```

Idle cues: an empty `❯` input line fenced by two `─` rules; the mode line ends
with the `· ← for agents` suffix; a `Context: N%` reading is present after the
first turn; no spinner line.

## 3. Busy signature

While working, a spinner line appears just above the top rule:

```
● Whirring…
────────────────────────────────────────────────
❯
────────────────────────────────────────────────
```

Busy cues: a `● <gerund>…` line where the verb rotates (Orchestrating, Whirring,
and others), and the `· ← for agents` suffix is ABSENT from the mode line. A
just-finished turn briefly shows `✻ <verb> for Ns` (for example
`✻ Crunched for 1s`). Assistant output lines are prefixed with `⏺`.

The rotating verb is exactly why classification must be JUDGMENT, not a fixed
regex on a word. The stable cue is the shape: a `● ...…` line present means
working.

## 4. Sending text and submitting

- Type text: `tmux send-keys -l -- "<text>" -t <pane>`. The `-l` (literal) flag
  matters: without it, a word matching a tmux key name would be interpreted as a
  key. With `-l`, the text is sent verbatim.
- Submit: a SEPARATE `tmux send-keys Enter -t <pane>`. Do not append Enter to the
  text call.
- A short delay (about 0.5s) between the text and the Enter is enough; the text
  reliably lands in the box before the Enter submits.

## 5. Multi-line prompts (open question #3 - answered)

All three methods compose a multi-line prompt in the box WITHOUT submitting:

1. `send-keys` with embedded newlines - newlines insert lines, they do not submit.
2. `send-keys -l` with embedded newlines - same, with literal safety. RECOMMENDED.
3. Bracketed paste - `printf '...' | tmux load-buffer -` then
   `tmux paste-buffer -p -t <pane>` (the `-p` enables bracketed paste).

A single trailing `send-keys Enter` then submits the whole block as ONE message
(verified: a 3-line block arrived as one user turn, drawing a single reply).
Recommended pattern: method 2 - one `send-keys -l` for the whole, possibly
multi-line, text, then a separate `Enter`. Bracketed paste is the fallback for
very large blocks.

## 6. No reliable single-key clear - so compose-then-submit

- `C-u` cleared only part of a multi-line box.
- `Escape` did not clear an idle box, and bracketed paste APPENDED to leftover
  text rather than replacing it.
- A long run of `BSpace` does clear it, but that is clumsy.

Operational rule: compose the entire message in one `send-keys -l` and submit it
immediately. Never leave partial text in the box. This sidesteps clearing
entirely, and is the discipline shaun must follow.

## 7. Interrupt is Escape - with a side effect

Sending `Escape` during generation interrupts the in-flight turn (a streaming
task stopped, no output produced). Side effect: the interrupted prompt is
RESTORED into the input box for re-editing. So after an interrupt, shaun must
overwrite or clear the box before composing a new message, or the new text will
append to the restored prompt.

## 8. Idle vs busy by double-snapshot (the classifier core)

Two `capture-pane -p` snapshots taken about 2s apart:

- IDLE: the snapshots are byte-for-byte IDENTICAL.
- BUSY: the snapshots DIFFER - output advanced, or the spinner frame changed.

This alone is a robust idle detector, independent of glyph specifics. Combined
with the static cues in sections 2 and 3, it is the heuristic shaun bootstraps
with, and the exact behavior timmy will turn into a tool:

```
busy          -> snapshots differ, or a ● ...… line is present
idle          -> snapshots identical, empty ❯ box, ← for agents suffix
waiting-input -> a selection menu is shown (section 9)
question      -> idle box, last assistant text ends in a question; needs
                 judgment or markers - mechanical detection is a post-PoC
                 timmy expansion
```

## 9. Selection / waiting-input signature

Interactive selection menus - the trust gate now, and permission prompts
post-PoC - render distinctly from a normal idle box:

```
❯ 1. <option one>
  2. <option two>
 Enter to confirm · Esc to cancel
```

Cue: numbered options with a `❯` cursor and an `Enter to confirm · Esc to cancel`
affordance line. This is the `waiting-input` state, and it is mechanically
detectable.

## 10. capture-pane fidelity

`capture-pane -p` faithfully reproduces the current rendered frame: box-drawing,
the spinner line, and partial streaming output. It is a true outside view - it
shows what a human would see, and nothing more. This is what makes the
abstraction gradient real: the driver literally cannot see more than the
rendered terminal.

## Net effect on the build

- **barn.sh**: launch the binary directly; per pane, accept the trust gate then
  poll `capture-pane` for the idle `❯` box before sending the role prompt; target
  panes by immutable pane id stored in `.barn-panes`.
- **shaun.md**: classify by double-snapshot plus the cues above (judgment, not
  regex); deliver prompts with `send-keys -l` then a separate `Enter`;
  compose-then-submit and never leave partial input; interrupt with `Escape` then
  overwrite the box.
- **timmy**: section 8 is its v0 specification in miniature - snapshot diffing
  plus the state cues, exposed as `busy|idle|waiting-input|question` with exit
  codes per state.
