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
# Snapshot-diff alone would call this idle; the spinner cue must force busy.
spin_sess="timmy_t_spin_$$"
tmux new-session -d -s "$spin_sess" -x 80 -y 24 \
  'printf "\xe2\x97\x8f Whirring\xe2\x80\xa6\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$spin_sess" busy 10 "stalled frame with spinner classified busy"

tmux kill-session -t "$spin_sess" 2>/dev/null

# --- fixture: a selection menu (the trust gate shape, smoke-test.md section 9).
# Numbered options with a cursor plus an "Enter to confirm" affordance line.
menu_sess="timmy_t_menu_$$"
tmux new-session -d -s "$menu_sess" -x 80 -y 24 \
  'printf "\xe2\x9d\xaf 1. Yes, I trust this folder\n  2. No, exit\n Enter to confirm \xc2\xb7 Esc to cancel\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$menu_sess" waiting-input 20 "selection menu classified waiting-input"

tmux kill-session -t "$menu_sess" 2>/dev/null

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
