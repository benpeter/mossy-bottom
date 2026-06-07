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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
