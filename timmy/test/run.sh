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
# Note: '%%' so the pane's printf emits a literal '%' (Context: 5%).
idle_box='\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/timmy | Opus 4.8 | Context: 5%%\n  bypass permissions on \xc2\xb7 \xe2\x86\x90 for agents\n'

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
