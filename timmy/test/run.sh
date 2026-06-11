#!/usr/bin/env bash
# timmy test harness - vanilla, no third-party deps.
# Spins up REAL tmux panes and classifies them through timmy's public CLI,
# so we exercise capture-pane and the double-snapshot core end-to-end.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
timmy="$here/../bin/timmy"

# Fast snapshots so the suite stays quick. timmy still takes two real captures.
export TIMMY_INTERVAL="${TIMMY_INTERVAL:-0.3}"

pass=0
fail=0

ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# assert_state <session> <expected-word> <expected-exit> <label>
assert_state() {
  local sess="$1" want_word="$2" want_code="$3" label="$4"
  local out code
  out="$("$timmy" --pane "$sess" 2>/dev/null)"
  code=$?
  if [ "$out" = "$want_word" ] && [ "$code" -eq "$want_code" ]; then
    ok "$label (got '$out' exit $code)"
  else
    no "$label (got '$out' exit $code; wanted '$want_word' exit $want_code)"
  fi
}

# --- fixture: an idle pane (static content, nothing advancing) ---
idle_sess="timmy_t_idle_$$"
tmux new-session -d -s "$idle_sess" -x 80 -y 24 \
  'printf "\xe2\x9d\xaf\n"; sleep 600' 2>/dev/null
sleep 0.5  # let the pane settle before we snapshot

assert_state "$idle_sess" idle 0 "static pane classified idle"

tmux kill-session -t "$idle_sess" 2>/dev/null

# --- fixture: a busy pane (output advances between snapshots) ---
busy_sess="timmy_t_busy_$$"
tmux new-session -d -s "$busy_sess" -x 80 -y 24 \
  'while true; do date +%s%N; sleep 0.05; done' 2>/dev/null
sleep 0.5

assert_state "$busy_sess" busy 10 "advancing pane classified busy"

tmux kill-session -t "$busy_sess" 2>/dev/null

# --- fixture: a STALLED pane - identical snapshots but a spinner is present.
# Snapshot-diff alone would call this idle; the spinner cue must force busy. The
# active spinner LINE carries its live counter in parens (e2 97 8f "●", e2 80 a6
# "…", c2 b7 "·"): "● Whirring… (esc to interrupt · 1.2k tokens)".
spin_sess="timmy_t_spin_$$"
tmux new-session -d -s "$spin_sess" -x 80 -y 24 \
  'printf "\xe2\x97\x8f Whirring\xe2\x80\xa6 (esc to interrupt \xc2\xb7 1.2k tokens)\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$spin_sess" busy 10 "stalled frame with spinner classified busy"

tmux kill-session -t "$spin_sess" 2>/dev/null

# --- GAP-1a (#9): the same active spinner but with an ASCII three-dot ellipsis
# "..." instead of the … glyph. The SHAPE cue must still read busy regardless of
# how the ellipsis renders - else a working pane reads idle and gets interrupted. ---
dots_sess="timmy_t_dots_$$"
tmux new-session -d -s "$dots_sess" -x 80 -y 24 \
  'printf "\xe2\x97\x8f Whirring... (esc to interrupt)\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$dots_sess" busy 10 "GAP-1a spinner with ASCII '...' ellipsis classified busy"

tmux kill-session -t "$dots_sess" 2>/dev/null

# --- GAP-1b (#9): an active spinner led by a DIFFERENT frame glyph than "●"
# (here U+2736 "✶" = e2 9c b6) with a past-tense verb. Glyph- and verb-agnostic:
# the shape (leading glyph + verb + ellipsis + counter) must still read busy. ---
glyph_sess="timmy_t_glyph_$$"
tmux new-session -d -s "$glyph_sess" -x 80 -y 24 \
  'printf "\xe2\x9c\xb6 Cooked\xe2\x80\xa6 (3s)\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$glyph_sess" busy 10 "GAP-1b spinner with alt glyph + past-tense verb classified busy"

tmux kill-session -t "$glyph_sess" 2>/dev/null

# --- #10 NOT-REGRESSED: a REAL spinner at the very bottom, with report content scrolled
# ABOVE it. The bottom spinner must still fire (busy) even though content precedes it -
# bottom-anchoring keeps the real live spinner, it only rejects content above. (No idle
# box here, so this can sit with the other spinner fixtures, before idle_box is defined.) ---
realspin_sess="timmy_t_realspin_$$"
tmux new-session -d -s "$realspin_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba Here is a lot of report content from the last turn.\n  more content.\n  even more content.\n\xe2\x97\x8f Whirring\xe2\x80\xa6 (esc to interrupt \xc2\xb7 1.2k tokens)\n'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$realspin_sess" busy 10 "#10 real bottom spinner with content above it -> busy"

tmux kill-session -t "$realspin_sess" 2>/dev/null

# --- #10 REAL-LAYOUT busy (the gap that defeated fixed-K=6): the PRODUCTION busy-pane
# bottom renders 6 rows BELOW the spinner - spinner / blank / rule / prompt / rule / footer
# A / footer B - so the spinner sits 7 rows from the bottom. The structural prompt-anchor
# must find it (skip the rule above the prompt and the blank, land on the spinner) and read
# busy. A fixed K=6 tail excluded row 7 and read this live busy pane as IDLE.
# Footer B carries NO "← for agents" suffix: a working footer never does (smoke-test.md
# section 3), so the #17 settled-idle override does not fire and the spinner decides. ---
reallayout_sess="timmy_t_reallayout_$$"
tmux new-session -d -s "$reallayout_sess" -x 80 -y 24 \
  "printf '\xe2\x97\x8f Processing... (6m 24s \xc2\xb7 esc to interrupt)\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/x | Opus 4.8 | Context: 41%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle)\n'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$reallayout_sess" busy 10 "#10 real production busy layout (spinner 7 rows up) -> busy"

tmux kill-session -t "$reallayout_sess" 2>/dev/null

# --- fixture: a selection menu (the trust gate shape, smoke-test.md section 9).
# Numbered options with a cursor plus an "Enter to confirm" affordance line.
menu_sess="timmy_t_menu_$$"
tmux new-session -d -s "$menu_sess" -x 80 -y 24 \
  'printf "\xe2\x9d\xaf 1. Yes, I trust this folder\n  2. No, exit\n Enter to confirm \xc2\xb7 Esc to cancel\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$menu_sess" waiting-input 20 "selection menu classified waiting-input"

tmux kill-session -t "$menu_sess" 2>/dev/null

# --- GAP-2 (#9) false-NEGATIVE: a REAL selection menu on a NARROW pane (width 14),
# where the "Enter to confirm" affordance WRAPS mid-phrase. The old phrase-based cue
# missed this (verified live); the structural shape - the "❯ <n>" cursor plus >=2
# numbered options, all short and left-aligned - survives the wrap. A miss here is the
# dangerous direction (a menu read as idle -> a driver types into the trust gate). ---
mnar_sess="timmy_t_mnar_$$"
tmux new-session -d -s "$mnar_sess" -x 14 -y 24 \
  'printf "\xe2\x9d\xaf 1. Yes\n  2. No\n Enter to confirm \xc2\xb7 Esc to cancel\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$mnar_sess" waiting-input 20 "GAP-2 narrow real menu (affordance wraps) classified waiting-input"

tmux kill-session -t "$mnar_sess" 2>/dev/null

# --- GAP-3 (#9) false-NEGATIVE: a REAL menu with ALTERNATE/absent affordance wording -
# no "Enter to confirm" phrase at all (a permission-style prompt). The shape (cursor +
# numbered options) must still classify waiting-input regardless of the affordance text. ---
malt_sess="timmy_t_malt_$$"
tmux new-session -d -s "$malt_sess" -x 80 -y 24 \
  'printf "\xe2\x9d\xaf 1. Allow this command\n  2. Deny\n  3. Always allow\n  Use arrow keys, then press return to choose\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$malt_sess" waiting-input 20 "GAP-3 real menu with alternate wording classified waiting-input"

tmux kill-session -t "$malt_sess" 2>/dev/null

# --- GAP-2 (#9) false-POSITIVE, the 14:17 case: a WORKING pane whose CONTENT is
# displaying the menu-detection source itself - "❯ 1." and "Enter to confirm" sit in the
# text - while an active spinner runs at the bottom. The old menu-first precedence read
# this as waiting-input (an obey-the-classifier driver would have injected a stray menu
# answer into a working session). Spinner-before-menu precedence must read it BUSY. ---
mfp_sess="timmy_t_mfp_$$"
tmux new-session -d -s "$mfp_sess" -x 80 -y 24 \
  'printf "\xe2\x8f\xba Editing has_menu: it keyed on \xe2\x9d\xaf 1. and the Enter to confirm line.\n  \xe2\x9d\xaf 1. Yes, I trust this folder\n    2. No, exit\n  Enter to confirm \xc2\xb7 Esc to cancel\n\xe2\x97\x8f Churning\xe2\x80\xa6 (esc to interrupt \xc2\xb7 2k tokens)\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$mfp_sess" busy 10 "GAP-2 working pane displaying menu source (14:17 case) classified busy, not menu"

tmux kill-session -t "$mfp_sess" 2>/dev/null

# A genuine Claude idle box: empty "❯" box fenced by rules, mode line ending in
# the "← for agents" suffix (smoke-test.md section 2). The two fixtures below
# differ only in whether the last assistant ("⏺") line ends in a question mark.
# Note: '%%' so the pane's printf emits a literal '%' (Context: 5%). The mode
# line carries the real "⏵⏵ ... (shift+tab to cycle) · ← for agents" shape.
idle_box='\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/timmy | Opus 4.8 | Context: 5%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle) \xc2\xb7 \xe2\x86\x90 for agents\n'

# --- fixture: idle box whose last assistant line ends in '?' -> question ---
q_sess="timmy_t_q_$$"
tmux new-session -d -s "$q_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba Want me to take question next, or harden idle first?\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$q_sess" question 30 "idle box ending in '?' classified question"

tmux kill-session -t "$q_sess" 2>/dev/null

# --- fixture: same genuine idle box, last assistant line ends in '.' -> idle.
# Proves the idle box is positively recognised and NOT misread as question. ---
ib_sess="timmy_t_ib_$$"
tmux new-session -d -s "$ib_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba All four states are wired up now.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$ib_sess" idle 0 "genuine idle box (ends in '.') classified idle"

tmux kill-session -t "$ib_sess" 2>/dev/null

# --- #17 the decoy gap: a SETTLED idle box (mode line carries the "← for agents" suffix)
# with a DECOY spinner-shaped line immediately above its top fence, no content between.
# Pre-#17 the spinner's structural anchor picked the decoy and read BUSY (false-positive
# busy -> shaun never hands work -> the chain stalls). The suffix now certifies the box
# settled and takes precedence OVER the spinner -> idle. Proves the override beats the
# spinner; this is the exact gap #17 closes. ---
decoy_sess="timmy_t_decoy_$$"
tmux new-session -d -s "$decoy_sess" -x 80 -y 24 \
  "printf '\xe2\x97\x8f Whirring\xe2\x80\xa6 (esc to interrupt \xc2\xb7 1.2k tokens)\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$decoy_sess" idle 0 "#17 decoy spinner immediately above a settled idle box (suffix present) -> idle, not busy"

tmux kill-session -t "$decoy_sess" 2>/dev/null

# --- #17 the binding criterion: a WORKING pane - active spinner, full box layout, but NO
# "← for agents" suffix (a working footer never carries it, smoke-test.md section 3).
# has_idle_suffix must NOT fire, so the spinner decides -> busy. Proves the override never
# false-negatives a working pane (mislabeling working as idle is the forbidden direction). ---
work_sess="timmy_t_work_$$"
tmux new-session -d -s "$work_sess" -x 80 -y 24 \
  "printf '\xe2\x97\x8f Processing\xe2\x80\xa6 (6m 24s \xc2\xb7 esc to interrupt)\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/x | Opus 4.8 | Context: 41%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle)\n'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$work_sess" busy 10 "#17 working pane, spinner active, NO suffix -> busy (never false-negative working)"

tmux kill-session -t "$work_sess" 2>/dev/null

# --- GAP-7 (#9): an idle pane whose CONTENT mentions a "●" bullet and a "…"
# ellipsis on one line, plus a "✻ Cooked for 5s" summary - the exact shapes that a
# finished report can contain. The OLD bare "●.*…" cue false-fired busy on such a
# line (it happened live to the operator's own instrument). The shape cue must read
# idle: none of these is an active spinner LINE (the glyphs are mid-line content, the
# summary has no immediate ellipsis or parenthesised counter). '⏺' = e2 8f ba. ---
g7_sess="timmy_t_g7_$$"
tmux new-session -d -s "$g7_sess" -x 100 -y 30 \
  "printf '\xe2\x8f\xba Report: a \xe2\x97\x8f bullet and a \xe2\x80\xa6 ellipsis share one line of content.\n  \xe2\x9c\xbb Cooked for 5s - this summary glyph is inline prose, not a live spinner.\n  All checks complete.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$g7_sess" idle 0 "GAP-7 idle report with inline ● bullet and ✻ summary classified idle, not busy"

tmux kill-session -t "$g7_sess" 2>/dev/null

# --- GAP-2 (#9) false-POSITIVE, settled variant: an IDLE pane (genuine "⏵⏵" box) whose
# CONTENT quotes a full menu - cursor line, numbered options, and an "Enter to confirm"
# line. The old menu-first precedence read this as waiting-input; the settled idle box is
# decided before the menu shape, so it must read idle. (The "❯" in the quoted menu carries
# an option number, so it is not the empty input box - box and menu stay distinct.) ---
mci_sess="timmy_t_mci_$$"
tmux new-session -d -s "$mci_sess" -x 100 -y 30 \
  "printf '\xe2\x8f\xba The menu cue keys on \xe2\x9d\xaf 1. plus an Enter to confirm line:\n  \xe2\x9d\xaf 1. Yes, I trust this folder\n    2. No, exit\n  Enter to confirm \xc2\xb7 Esc to cancel\n  Done reviewing the menu cue.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$mci_sess" idle 0 "GAP-2 idle pane quoting a full menu in content classified idle, not menu"

tmux kill-session -t "$mci_sess" 2>/dev/null

# A NARROW idle box (width 50): the mode line truncates before "← for agents"
# (verified empirically against a live session: "...(shift+tab to cycle ·"). The
# width-robust cues - the "⏵⏵" mode marker and the empty "❯" box - must still
# identify the idle box so question/idle work at narrow widths. '%%' -> '%'.
narrow_box='\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/t | Opus 4.8 | Ctx 5%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle \xc2\xb7\n'

# --- fixture: narrow idle box whose last assistant line ends in '?' -> question.
nq_sess="timmy_t_nq_$$"
tmux new-session -d -s "$nq_sess" -x 50 -y 24 \
  "printf '\xe2\x8f\xba Should I proceed with the merge?\n${narrow_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$nq_sess" question 30 "narrow idle box ending in '?' classified question"

tmux kill-session -t "$nq_sess" 2>/dev/null

# --- fixture: same narrow box, last line ends in '.' -> idle (guard). ---
ni_sess="timmy_t_ni_$$"
tmux new-session -d -s "$ni_sess" -x 50 -y 24 \
  "printf '\xe2\x8f\xba All settled now.\n${narrow_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$ni_sess" idle 0 "narrow idle box (ends in '.') classified idle"

tmux kill-session -t "$ni_sess" 2>/dev/null

# --- #22 (the #17 narrow residual): a narrow idle box whose FULL mode line WRAPS, the
# realistic case where tmux wraps the footer rather than Claude truncating it. The
# wrapped continuation FRAGMENTS ("xt: 5%" from "Context: 5%", "agents" from "← for
# agents") carry none of the box-chrome keywords, so the old whitelist "only box-chrome
# below" check DROPPED the box (idle_box=false) - and every idle-box-gated state then
# misclassified. This differs from the `narrow_box` fixtures above, which keep the footer
# on ONE pre-truncated line and so already pass. The mode line below is the full
# "⏵⏵ ... (shift+tab to cycle) · ← for agents" shape; at width 30 tmux wraps it. '%%' -> '%'.
wrap_box='\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/timmy | Opus 4.8 | Context: 5%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle) \xc2\xb7 \xe2\x86\x90 for agents\n'

# RED before this slice: the wrapped footer dropped the box, so the question state was
# lost and this read idle/0. The box must be recognised at narrow width -> question/30.
wrapq_sess="timmy_t_wrapq_$$"
tmux new-session -d -s "$wrapq_sess" -x 30 -y 18 \
  "printf '\xe2\x8f\xba Should I proceed with the merge?\n${wrap_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$wrapq_sess" question 30 "#22 narrow WRAPPED-footer idle box ending in '?' classified question"

tmux kill-session -t "$wrapq_sess" 2>/dev/null

# A narrow WRAPPED-footer idle box (statement) must be POSITIVELY recognised AS A BOX -
# idle by box recognition, not merely by the snapshot-diff fallback that masked the bug
# for a settled statement. Asserting idle_box=true via --json pins the fix: a future
# regression that drops the box (back to lucky fallback idle) trips here, not silently.
wrapi_sess="timmy_t_wrapi_$$"
tmux new-session -d -s "$wrapi_sess" -x 30 -y 18 \
  "printf '\xe2\x8f\xba All settled now.\n${wrap_box}'; sleep 600" 2>/dev/null
sleep 0.5

wrapi_json="$("$timmy" --pane "$wrapi_sess" --json 2>/dev/null)"
wrapi_code=$?
if [ "$wrapi_code" -eq 0 ] && [[ "$wrapi_json" == *'"state":"idle"'* ]] && [[ "$wrapi_json" == *'"idle_box":true'* ]]; then
  ok "#22 narrow WRAPPED-footer idle box positively recognised (idle, idle_box=true)"
else
  no "#22 narrow WRAPPED-footer idle box positively recognised (got '$wrapi_json' exit $wrapi_code)"
fi

tmux kill-session -t "$wrapi_sess" 2>/dev/null

# --- #23 (the #22 decoy residual): a GENUINELY WORKING pane whose content RENDERS idle-box
# chrome but whose content CHANGES across snapshots - the worker mid-slice, its own idle-box
# fixtures in view, no Claude spinner. Pre-#23 is_idle_box (step 2) overrode the snapshot diff
# unconditionally, so this read idle/0 (a FALSE-IDLE: a still-working worker reported finished,
# the dangerous direction - a driver could hand the next slice into a live pane). The box has a
# WORKING footer (no "← for agents"), so idle_suffix does not fire and it reaches the idle_box
# branch. A counter line is redrawn every 0.1s ABOVE the box via home-cursor (no clear -> no
# blank-frame race; the box is always present, so idle_box stays true) - so snapshots persist
# in differing and sustained_motion confirms genuine work -> busy. '⏵⏵' = e2 8f b5 (no suffix).
live_box='\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/timmy | Opus 4.8 | Context: 5%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle)\n'

# RED before this slice: idle_box overrode the diff -> idle/0. After: persistent motion wins.
motion_sess="timmy_t_motion_$$"
tmux new-session -d -s "$motion_sess" -x 80 -y 24 \
  "i=0; while true; do printf '\033[Hworking %d\033[K\n${live_box}' \"\$i\"; i=\$((i+1)); sleep 0.1; done" 2>/dev/null
sleep 0.6  # let the first frame paint and the counter start advancing

assert_state "$motion_sess" busy 10 "#23 working pane rendering idle-box chrome + persistent motion -> busy, not idle"

# Pin the #23 path precisely: the box WAS recognised (idle_box=true) yet liveness won
# (state busy, sustained_motion=true) - so this is the decoy fix, not a spinner firing.
motion_json="$("$timmy" --pane "$motion_sess" --json 2>/dev/null)"
motion_code=$?
if [ "$motion_code" -eq 10 ] && [[ "$motion_json" == *'"state":"busy"'* ]] \
  && [[ "$motion_json" == *'"idle_box":true'* ]] && [[ "$motion_json" == *'"sustained_motion":true'* ]]; then
  ok "#23 idle-box chrome present yet persistent motion classified busy (idle_box=true, sustained_motion=true)"
else
  no "#23 idle-box chrome + persistent motion (got '$motion_json' exit $motion_code)"
fi

tmux kill-session -t "$motion_sess" 2>/dev/null

# --- #23 GUARD (the discriminator is MOTION, not the box shape): the SAME no-suffix box,
# STATIC. sustained_motion is never even called (differ=false), so the box decides -> idle.
# Proves the fix flips ONLY on persistent motion and does NOT regress a settled idle box. ---
still_sess="timmy_t_still_$$"
tmux new-session -d -s "$still_sess" -x 80 -y 24 \
  "printf 'all settled now.\n${live_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$still_sess" idle 0 "#23 guard: the SAME box STATIC (no motion) stays idle - motion is the discriminator"

tmux kill-session -t "$still_sess" 2>/dev/null

# A MULTI-LINE assistant turn (reconstructed from a verbatim live capture): the
# question is an indented CONTINUATION line (no "⏺" prefix), followed by the
# "✻ ... for Ns" post-turn timer and a tip footer. The last content line of the
# message - not the last "⏺" line - is the question. '✻' = e2 9c bb.
mlq_sess="timmy_t_mlq_$$"
tmux new-session -d -s "$mlq_sess" -x 100 -y 30 \
  "printf '\xe2\x8f\xba - tmux lets you run multiple terminal sessions in one window via splits and panes.\n  - tmux sessions persist after you detach, so long-running work survives disconnects.\n\n  Which one do you want me to explain?\n\n\xe2\x9c\xbb Cooked for 5s\n  tmux focus-events off, a footer tip ending in a period.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$mlq_sess" question 30 "multi-line turn (question as continuation line) classified question"

tmux kill-session -t "$mlq_sess" 2>/dev/null

# Guard: a statement as the last content line, with ADVERSARIAL chrome - the tip
# footer below "✻" ends in '?'. The footer must not mask the real last line, and
# must not fabricate a question: this must read idle, not question.
cs_sess="timmy_t_cs_$$"
tmux new-session -d -s "$cs_sess" -x 100 -y 30 \
  "printf '\xe2\x8f\xba All four states are wired up now.\n\n\xe2\x9c\xbb Cooked for 1s\n  Tip: press ? for keyboard shortcuts?\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$cs_sess" idle 0 "statement with adversarial '?' chrome footer classified idle"

tmux kill-session -t "$cs_sess" 2>/dev/null

# A FULLY-SETTLED frame: the "✻ ... for Ns" post-turn timer has DISAPPEARED, but
# a tip/hint footer still lingers directly above the input box. The timer was the
# anchor the cut relied on; with it gone, the footer must NOT be mistaken for the
# closing content line. Here the true last line is a question, the lingering
# footer is a real-shaped hint line ("... · ..."). The footer must be stripped by
# its own signature so the question still wins. '·' = c2 b7.
ntq_sess="timmy_t_ntq_$$"
tmux new-session -d -s "$ntq_sess" -x 100 -y 30 \
  "printf '\xe2\x8f\xba Here are two tmux concepts worth knowing.\n  Which one do you want me to explain?\n\n  esc to interrupt \xc2\xb7 ctrl+t to show todos\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$ntq_sess" question 30 "settled frame, timer gone, lingering hint footer, question survives"

tmux kill-session -t "$ntq_sess" 2>/dev/null

# Same shape, adversarial: timer gone, true last line is a STATEMENT, and the
# lingering "Tip:" footer itself ends in '?'. The footer must be stripped (not
# treated as content) and must not fabricate a question: this reads idle.
nts_sess="timmy_t_nts_$$"
tmux new-session -d -s "$nts_sess" -x 100 -y 30 \
  "printf '\xe2\x8f\xba All four states are wired up now.\n\n  Tip: press ? for keyboard shortcuts?\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$nts_sess" idle 0 "settled frame, timer gone, adversarial '?' tip footer, stays idle"

tmux kill-session -t "$nts_sess" 2>/dev/null

# --- GAP-4 (#9): a NARROW pane (width 50) where the post-turn timer's trailing hint
# WRAPS, so "for Ns" is no longer at the line end. The old end-anchored timer regex
# (✻.*for [0-9]+s *$) missed the timer here and could mislocate the closing line; the
# shape-based timer chrome (glyph-led + elapsed token, not end-anchored) still stops
# the scan, so the real question survives. '✻' = e2 9c bb. ---
g4_sess="timmy_t_g4_$$"
tmux new-session -d -s "$g4_sess" -x 50 -y 24 \
  "printf '\xe2\x8f\xba Here is the tradeoff you asked about.\n  Which option should I take?\n\xe2\x9c\xbb Sauteed for 5s (esc to interrupt \xc2\xb7 ctrl+t to show todos)\n${narrow_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$g4_sess" question 30 "GAP-4 narrow pane, timer trailing hint wraps, question survives"

tmux kill-session -t "$g4_sess" 2>/dev/null

# --- GAP-5 (#9): a post-turn timer with a CHANGED glyph and wording - "✦ Cooked (5s)"
# instead of "✻ Cooked for 5s". The old timer regex keyed on "✻" and "for Ns" and would
# miss this, then mistake the timer line for the closing content and degrade to idle. The
# glyph-agnostic shape (any non-⏺ glyph + elapsed token) still strips it. '✦' = e2 9c a6. ---
g5_sess="timmy_t_g5_$$"
tmux new-session -d -s "$g5_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba Two approaches are possible here.\n  Which approach do you prefer?\n\xe2\x9c\xa6 Cooked (5s)\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$g5_sess" question 30 "GAP-5 alt timer glyph and wording, question survives"

tmux kill-session -t "$g5_sess" 2>/dev/null

# --- GAP-6 (#9): a real idle box WITHOUT the "⏵⏵" mode marker (and no "shift+tab") -
# only the "─" rule fence and the empty "❯". Question detection used to require "⏵⏵", so
# a changed/absent marker silently degraded a real question to idle. is_idle_box now
# corroborates on any one box cue (here the rules), so the box - and the question - hold.
# '─' = e2 94 80, '❯' = e2 9d af; '%%' -> literal '%'. ---
g6_box='\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/proj | Opus 4.8 | Context: 9%%\n'
g6_sess="timmy_t_g6_$$"
tmux new-session -d -s "$g6_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba I need a decision before continuing.\n  Should I proceed with the deploy?\n${g6_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$g6_sess" question 30 "GAP-6 idle box WITHOUT the ⏵⏵ marker, question survives"

tmux kill-session -t "$g6_sess" 2>/dev/null

# --- GAP-8 (#9): a genuine CLOSING QUESTION that itself contains "·". The old timer-gone
# branch stripped ANY line containing " · " as chrome, deleting such a question and
# degrading to idle. Chrome is now matched by signature, never by "·", so the question
# survives. '·' = c2 b7. ---
g8_sess="timmy_t_g8_$$"
tmux new-session -d -s "$g8_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba A few routing options exist.\n  Use route A \xc2\xb7 route B \xc2\xb7 route C?\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$g8_sess" question 30 "GAP-8 closing question containing '·' classified question, not stripped"

tmux kill-session -t "$g8_sess" 2>/dev/null

# --- GAP-8 guard (#9), inverse: a "·"-bearing line that IS chrome (a key-hint footer)
# above a STATEMENT must still be stripped, and must not fabricate a question - stays
# idle. Proves the signature-based strip still removes real "·" chrome. ---
g8g_sess="timmy_t_g8g_$$"
tmux new-session -d -s "$g8g_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba All checks are complete now.\n  esc to interrupt \xc2\xb7 ctrl+t to show todos\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$g8g_sess" idle 0 "GAP-8 guard: '·' key-hint chrome stripped, statement stays idle"

tmux kill-session -t "$g8g_sess" 2>/dev/null

# --- #10 SHADOW-REJECTION: a spinner-shaped line sits in CONTENT above a real IDLE box
# at the very bottom. Before bottom-anchoring the spinner fired on the content glyph and
# read busy (reproduced live); now the spinner cue reads only the bottom region, so the
# content spinner cannot shadow the real idle box. Must read idle, not busy. ---
shspin_idle_sess="timmy_t_shspin_idle_$$"
tmux new-session -d -s "$shspin_idle_sess" -x 80 -y 24 \
  "printf '\xe2\x97\x8f Churning\xe2\x80\xa6 (esc to interrupt \xc2\xb7 1.2k tokens)\n  my report quotes that captured spinner line above; I am actually idle.\n  another line of the report.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$shspin_idle_sess" idle 0 "#10 content spinner above a real idle box -> idle, not busy"

tmux kill-session -t "$shspin_idle_sess" 2>/dev/null

# --- #10 SHADOW-REJECTION: a content spinner above a real QUESTION at the bottom. The
# real bottom state (an idle box whose closing line is a question) must win. ---
shspin_q_sess="timmy_t_shspin_q_$$"
tmux new-session -d -s "$shspin_q_sess" -x 80 -y 24 \
  "printf '\xe2\x97\x8f Propagating\xe2\x80\xa6 (esc to interrupt)\n\xe2\x8f\xba Should I proceed with the merge?\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$shspin_q_sess" question 30 "#10 content spinner above a real question -> question, not busy"

tmux kill-session -t "$shspin_q_sess" 2>/dev/null

# A QUOTED idle box as scrollback CONTENT (a full box - rule/❯/rule/footer - displayed in
# a report, e.g. smoke-test.md). It has its own empty "❯", which the old is_idle_box fired
# on from anywhere. The #10 anchor must reject it as the input box (it has real content
# below it), so it cannot shadow the real bottom state. '%%' -> literal '%'.
quoted_box='  (a displayed report quotes a full idle box:)\n  \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  \xe2\x9d\xaf\n  \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/quoted | Opus 4.8 | Context: 5%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle) \xc2\xb7 \xe2\x86\x90 for agents\n  (end of the quoted box)\n'

# --- #10 idle-box POSITIVE (real production box height): a REAL idle box at the very
# bottom with substantial content above it -> idle. Models the real box (rule/❯/rule/
# footerA/footerB), not a short stub. ---
ibreal_sess="timmy_t_ibreal_$$"
tmux new-session -d -s "$ibreal_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba Here is a long report from the last turn.\n  line two of the report.\n  line three.\n  all settled now.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$ibreal_sess" idle 0 "#10 real idle box at bottom with content above -> idle"

tmux kill-session -t "$ibreal_sess" 2>/dev/null

# --- #10 SHADOW-REJECTION (the menu-masking case, reproduced in the audit): a quoted idle
# box in scrollback ABOVE a real MENU at the bottom. The old cue fired idle_box on the
# quote and read idle (a driver would type INTO the menu); the anchor rejects the quote, so
# the menu wins -> waiting-input. ---
ibmenu_sess="timmy_t_ibmenu_$$"
tmux new-session -d -s "$ibmenu_sess" -x 80 -y 24 \
  "printf '${quoted_box}  a REAL permission menu is now live below:\n\xe2\x9d\xaf 1. Yes, I trust this folder\n  2. No, exit\n Enter to confirm \xc2\xb7 Esc to cancel\n'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$ibmenu_sess" waiting-input 20 "#10 quoted idle box above a real menu -> waiting-input, not idle"

tmux kill-session -t "$ibmenu_sess" 2>/dev/null

# --- #10 SHADOW-REJECTION: a quoted idle box ABOVE a real BUSY spinner (the full working
# layout: spinner/blank/rule/prompt/rule/footerA/footerB). Must read busy. ---
ibspin_sess="timmy_t_ibspin_$$"
tmux new-session -d -s "$ibspin_sess" -x 80 -y 24 \
  "printf '${quoted_box}\xe2\x97\x8f Processing... (6m 24s \xc2\xb7 esc to interrupt)\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/x | Opus 4.8 | Context: 41%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle)\n'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$ibspin_sess" busy 10 "#10 quoted idle box above a real busy spinner -> busy"

tmux kill-session -t "$ibspin_sess" 2>/dev/null

# --- #10 SHADOW-REJECTION: a quoted idle box ABOVE a real QUESTION at the bottom. The real
# bottom question box must win (question gated on idle-box, protected by the anchor). ---
ibq_sess="timmy_t_ibq_$$"
tmux new-session -d -s "$ibq_sess" -x 80 -y 24 \
  "printf '${quoted_box}\xe2\x8f\xba Should I proceed with the merge?\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$ibq_sess" question 30 "#10 quoted idle box above a real question -> question"

tmux kill-session -t "$ibq_sess" 2>/dev/null

# A frozen numbered-list / quoted menu as scrollback CONTENT (the GAP-2 residual shape).
# The old has_menu fired on it from anywhere; the #10 anchor must reject it when a real
# bottom state renders below it.
quoted_menu='  (a displayed report quotes a selection menu:)\n  \xe2\x9d\xaf 1. Yes, I trust this folder\n    2. No, exit\n   Enter to confirm \xc2\xb7 Esc to cancel\n  (end of the quoted menu)\n'

# --- #10 menu SHADOW-REJECTION: a frozen numbered list in scrollback ABOVE a real IDLE box
# at the bottom. The quoted menu must not read as a live menu - the real idle box wins. ---
mqi_sess="timmy_t_mqi_$$"
tmux new-session -d -s "$mqi_sess" -x 80 -y 24 \
  "printf '${quoted_menu}  all settled now.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$mqi_sess" idle 0 "#10 frozen numbered list above a real idle box -> idle, not menu"

tmux kill-session -t "$mqi_sess" 2>/dev/null

# --- #10 menu SHADOW-REJECTION: a frozen numbered list in scrollback ABOVE a real BUSY
# spinner (full working layout). Must read busy. ---
mqs_sess="timmy_t_mqs_$$"
tmux new-session -d -s "$mqs_sess" -x 80 -y 24 \
  "printf '${quoted_menu}\xe2\x97\x8f Processing... (6m 24s \xc2\xb7 esc to interrupt)\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/x | Opus 4.8 | Context: 41%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle)\n'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$mqs_sess" busy 10 "#10 frozen numbered list above a real busy spinner -> busy"

tmux kill-session -t "$mqs_sess" 2>/dev/null

# --- #10 menu NOT-REGRESSED: a quoted menu in scrollback ABOVE a real LIVE menu at the
# bottom. The real bottom menu still wins -> waiting-input (the anchor anchors on the
# BOTTOM-most option, whose tail is only the affordance). ---
mqm_sess="timmy_t_mqm_$$"
tmux new-session -d -s "$mqm_sess" -x 80 -y 24 \
  "printf '${quoted_menu}  a REAL menu is now live below:\n\xe2\x9d\xaf 1. Allow this command\n  2. Deny\n  3. Always allow\n  Use arrow keys, then press return to choose\n'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$mqm_sess" waiting-input 20 "#10 quoted menu above a real live menu -> waiting-input"

tmux kill-session -t "$mqm_sess" 2>/dev/null

# --- #10 question SHADOW-REJECTION: a question shape in SCROLLBACK above a real idle box
# whose own last turn is a STATEMENT. ends_in_question anchors on the bottom-most box and
# the LAST turn, so the scrollback question does not make it read question -> idle. ---
qshadow_idle_sess="timmy_t_qshadow_idle_$$"
tmux new-session -d -s "$qshadow_idle_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba Should I proceed with the risky thing?\n  (older output scrolled up)\n\xe2\x8f\xba All settled now.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$qshadow_idle_sess" idle 0 "#10 question in scrollback above a real idle box (statement) -> idle"

tmux kill-session -t "$qshadow_idle_sess" 2>/dev/null

# --- #10 question SHADOW-REJECTION: a question shape in SCROLLBACK above a real BUSY
# spinner (full working layout). Spinner wins -> busy, not question. ---
qshadow_busy_sess="timmy_t_qshadow_busy_$$"
tmux new-session -d -s "$qshadow_busy_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba Should I proceed?\n\xe2\x97\x8f Processing... (6m 24s \xc2\xb7 esc to interrupt)\n\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/x | Opus 4.8 | Context: 41%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle)\n'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$qshadow_busy_sess" busy 10 "#10 question in scrollback above a real busy spinner -> busy"

tmux kill-session -t "$qshadow_busy_sess" 2>/dev/null

# --- #10 question RESIDUAL (the issue's named false-negative): a real closing question
# with the timer GONE and a RADICALLY REWORDED key-hint footer below it (none of #9's known
# hint phrases: "↵ to select · esc to dismiss"). Question detection must NOT depend on the
# footer wording or the timer - the "·"-hint-separator (not ending in "?") marks the footer
# as chrome by shape, so the question above it still wins. '↵' = e2 86 b5. ---
qreword_sess="timmy_t_qreword_$$"
tmux new-session -d -s "$qreword_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba Here are the options I see.\n  Which approach do you prefer?\n\n  \xe2\x86\xb5 to select \xc2\xb7 esc to dismiss\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$qreword_sess" question 30 "#10 reworded key-hint footer, timer gone, below a real question -> question"

tmux kill-session -t "$qreword_sess" 2>/dev/null

# --- #10 question RESIDUAL guard (inverse): the same reworded "·" hint footer below a
# STATEMENT must NOT fabricate a question - stays idle. Proves the "·"-not-"?" footer strip
# does not turn a statement into a question. ---
qreword_guard_sess="timmy_t_qrewordg_$$"
tmux new-session -d -s "$qreword_guard_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba All four states are wired up now.\n\n  \xe2\x86\xb5 to select \xc2\xb7 esc to dismiss\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$qreword_guard_sess" idle 0 "#10 reworded '·' hint footer below a statement -> idle, not question"

tmux kill-session -t "$qreword_guard_sess" 2>/dev/null

# --- fixture: --watch emits one line per state CHANGE only ---
# Drive a pane through idle -> busy -> idle and assert watch prints EXACTLY three
# lines in that order, with NO duplicate while a state is held. The pane holds
# each state ~2s; watch polls at TIMMY_INTERVAL. busy is forced by the spinner
# cue (deterministic on a static frame), idle by static plain content.
w_sess="timmy_t_watch_$$"
w_out="$(mktemp "${TMPDIR:-/tmp}/timmy-watch-XXXXXX")"
tmux new-session -d -s "$w_sess" -x 80 -y 24 \
  "printf 'IDLE-A\n'; sleep 2; printf '\xe2\x97\x8f Whirring\xe2\x80\xa6 (esc to interrupt)\n'; sleep 2; clear; printf 'IDLE-B\n'; sleep 600" 2>/dev/null
sleep 0.5  # let IDLE-A paint before watch takes its first read

"$timmy" --watch --pane "$w_sess" > "$w_out" 2>/dev/null &
w_pid=$!
sleep 6                       # span all three phases (idle, busy, idle)
kill "$w_pid" 2>/dev/null     # SIGTERM -> watch must exit cleanly, flushing output
wait "$w_pid" 2>/dev/null

w_seq="$(awk '{print $1}' "$w_out" | tr '\n' ',')"
w_n=$(awk 'END{print NR}' "$w_out")
if [ "$w_n" -eq 3 ] && [ "$w_seq" = "idle,busy,idle," ]; then
  ok "watch emits idle,busy,idle once each on change (got '$w_seq')"
else
  no "watch emits idle,busy,idle once each on change (got '$w_seq' in $w_n lines)"
fi

tmux kill-session -t "$w_sess" 2>/dev/null
rm -f "$w_out"

# --- fixture: a BLANK pane (no output at all). An empty capture is NOT an error:
# two identical empty snapshots classify idle via the snapshot-diff fallback. This
# guards the boundary between "empty" (idle) and "capture failed" (the error below). ---
blank_sess="timmy_t_blank_$$"
tmux new-session -d -s "$blank_sess" -x 80 -y 24 'sleep 600' 2>/dev/null
sleep 0.5

assert_state "$blank_sess" idle 0 "blank pane (empty capture) classified idle, not error"

tmux kill-session -t "$blank_sess" 2>/dev/null

# --- fixture: a GONE pane - capture-pane FAILS. The classify-error path: --await
# must exit EXIT_WATCH_ERR (65), not hang or spin. We target a session that was
# never created, so the first capture fails immediately. (single-shot would die 64;
# 65 is the watch/await error code, reused so the modes cannot drift.) ---
gone_sess="timmy_t_gone_$$" # intentionally never created
"$timmy" --await --pane "$gone_sess" --timeout 1 >/dev/null 2>&1
gone_code=$?
if [ "$gone_code" -eq 65 ]; then
  ok "capture failure on a gone pane exits 65 (EXIT_WATCH_ERR)"
else
  no "capture failure on a gone pane exits 65 (got exit $gone_code)"
fi

# --- fixture: --json serialises the classifier output. An idle pane must emit a
# JSON object whose state is "idle" with exit 0 - the structured-output path, not
# just the bare state word. ---
json_sess="timmy_t_json_$$"
tmux new-session -d -s "$json_sess" -x 80 -y 24 \
  'printf "\xe2\x9d\xaf\n"; sleep 600' 2>/dev/null
sleep 0.5

json_out="$("$timmy" --pane "$json_sess" --json 2>/dev/null)"
json_code=$?
if [ "$json_code" -eq 0 ] && [[ "$json_out" == '{"state":"idle",'* ]]; then
  ok "--json emits an idle state object, exit 0"
else
  no "--json idle object (got '$json_out' exit $json_code)"
fi

tmux kill-session -t "$json_sess" 2>/dev/null

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
