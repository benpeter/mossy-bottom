#!/usr/bin/env bash
# stuck-check.test.sh - hermetic, launch-free tests for bin/stuck-check.sh (Issue #20,
# slice 1). No tmux, no timmy, no heartbeat: we SOURCE stuck-check.sh under its BASH_SOURCE
# guard (so main() never runs) and drive classify_turn directly over a fixture TABLE, then
# spot-check the CLI exit codes.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
sc="$here/stuck-check.sh"

# shellcheck source=/dev/null
. "$sc"
set +o pipefail # relax for the harness assertions

# Live-pane (--pane mode) fixtures use REAL throwaway tmux panes and the real timmy
# classifier (no claude). Keep timmy's two-snapshot interval short so the suite stays quick;
# everything is torn down on exit.
export TIMMY_INTERVAL="${TIMMY_INTERVAL:-0.3}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/stuck-check-test-XXXXXX")"
# INT TERM as well as EXIT: bash skips an EXIT-only trap when it is killed by a signal, so an
# interrupted run left its fixture panes behind. 22 of them were found alive on 2026-07-31 after a
# suite was cut short, and a stray session is not harmless - barn scans the session list to pick a
# window name and the attached session.
trap 'rm -rf "$tmp"' EXIT INT TERM

pass=0
fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# Fixture TABLE: "<state> <has_standby> <changed> <expected-verdict>". Covers the three
# required edges plus the invariant that ANY non-idle state, and any changed=1, is working
# regardless of the other two inputs.
table=(
  # any non-idle state is working, whatever has_standby / changed are
  "busy     0 0 working"
  "busy     1 0 working"
  "busy     0 1 working"
  "waiting  0 0 working"
  "waiting  1 1 working"
  "question 0 0 working"
  "question 1 0 working"
  # idle but advancing -> working (carries the legit-await case via changed=1)
  "idle     0 1 working"
  "idle     1 1 working"
  # idle + stable + STANDBY -> a legitimate paused turn
  "idle     1 0 standby"
  # idle + stable + NO standby -> the dead, frozen turn
  "idle     0 0 stuck"
  # #28: a frozen-spinner 'stalled' turn (timmy exit 40, #25) is WEDGED -> stuck, not working.
  # A frozen spinner cannot be a legit STANDBY pause, so stalled -> stuck even WITH a marker
  # (has_standby is not consulted). RED today: current code maps any non-idle state to working.
  "stalled  0 0 stuck"
  "stalled  1 0 stuck"
  # ...but the safe direction holds: a pane that ADVANCED this interval (changed=1) is never
  # called stuck, even if momentarily read stalled - it gets another heartbeat cycle.
  "stalled  0 1 working"
  "stalled  1 1 working"
)

printf '== verdict table (state / has_standby / changed -> verdict) ==\n'
for row in "${table[@]}"; do
  read -r state hs ch want <<<"$row"
  got="$(classify_turn "$state" "$hs" "$ch")"
  if [ "$got" = "$want" ]; then
    ok "$(printf '%-8s standby=%s changed=%s -> %s' "$state" "$hs" "$ch" "$got")"
  else
    no "$(printf '%-8s standby=%s changed=%s -> %s (wanted %s)' "$state" "$hs" "$ch" "$got" "$want")"
  fi
done

# CLI spot-checks: the verdict word AND the per-verdict exit code, end to end.
printf '\n== CLI exit codes ==\n'
cli_case() {
  local label="$1" want_word="$2" want_code="$3"
  shift 3
  local out code
  out="$("$sc" "$@" 2>/dev/null)"
  code=$?
  if [ "$out" = "$want_word" ] && [ "$code" -eq "$want_code" ]; then
    ok "$label (got '$out' exit $code)"
  else
    no "$label (got '$out' exit $code; wanted '$want_word' exit $want_code)"
  fi
}
cli_case "CLI busy -> working/0" working 0 --state busy --has-standby 0 --changed 0
cli_case "CLI idle+standby -> standby/10" standby 10 --state idle --has-standby 1 --changed 0
cli_case "CLI idle+no-standby -> stuck/20" stuck 20 --state idle --has-standby 0 --changed 0
cli_case "CLI idle+changed -> working/0" working 0 --state idle --has-standby 0 --changed 1
# #28: the CLI accepts 'stalled' and routes a frozen turn to stuck; changed=1 still wins (safe dir).
cli_case "CLI stalled -> stuck/20 (#28)" stuck 20 --state stalled --has-standby 0 --changed 0
cli_case "CLI stalled+marker -> stuck/20 (#28, marker ignored)" stuck 20 --state stalled --has-standby 1 --changed 0
cli_case "CLI stalled+changed -> working/0 (#28 safe dir)" working 0 --state stalled --has-standby 0 --changed 1

# usage errors are exit 64, never a verdict
"$sc" --state idle --has-standby 0 >/dev/null 2>&1
code=$?
if [ "$code" -eq 64 ]; then ok "CLI missing --changed -> usage error 64"; else no "CLI missing --changed -> usage error 64 (got $code)"; fi
"$sc" --state bogus --has-standby 0 --changed 0 >/dev/null 2>&1
code=$?
if [ "$code" -eq 64 ]; then ok "CLI invalid --state -> usage error 64"; else no "CLI invalid --state -> usage error 64 (got $code)"; fi

# ============================================================================
# Live-pane mode (--pane): gather inputs from REAL throwaway tmux panes (no claude).
# state <- timmy; has_standby <- the capture; changed <- a CROSS-call fingerprint file.
# ============================================================================
idle_box='\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/t | Opus 4.8 | Context: 5%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle) \xc2\xb7 \xe2\x86\x90 for agents\n'

sc_live() {
  local label="$1" sess="$2" fp="$3" want_word="$4" want_code="$5" out code
  out="$("$sc" --pane "$sess" --fingerprint-file "$fp" 2>/dev/null)"
  code=$?
  if [ "$out" = "$want_word" ] && [ "$code" -eq "$want_code" ]; then
    ok "$label (got '$out' exit $code)"
  else
    no "$label (got '$out' exit $code; wanted '$want_word' exit $want_code)"
  fi
}

printf '\n== live-pane verdicts (real tmux panes, real timmy) ==\n'

# STUCK: idle box, NO STANDBY. First call assumes alive (no prior fp); the second identical
# call is changed=0 -> the dead, frozen turn.
ss="sct_stuck_$$"
tmux new-session -d -s "$ss" -x 80 -y 24 "printf '\xe2\x8f\xba all settled now.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5
sc_live "stuck call 1 (no prior fp -> assume alive)" "$ss" "$tmp/stuck.fp" working 0
sc_live "stuck call 2 (idle, stable, no STANDBY -> stuck)" "$ss" "$tmp/stuck.fp" stuck 20
tmux kill-session -t "$ss" 2>/dev/null

# STANDBY: idle box WITH a STANDBY line. Second stable call -> a legit paused turn.
sb="sct_standby_$$"
tmux new-session -d -s "$sb" -x 80 -y 24 "printf '\xe2\x8f\xba STANDBY (context) - resume monitoring shirley.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5
sc_live "standby call 1 (assume alive)" "$sb" "$tmp/standby.fp" working 0
sc_live "standby call 2 (idle, stable, STANDBY present -> standby)" "$sb" "$tmp/standby.fp" standby 10
tmux kill-session -t "$sb" 2>/dev/null

# WORKING: a spinner. A non-idle state short-circuits to working on the first call.
sw="sct_work_$$"
tmux new-session -d -s "$sw" -x 80 -y 24 'printf "\xe2\x97\x8f Whirring\xe2\x80\xa6 (esc to interrupt \xc2\xb7 1.2k tokens)\n"; sleep 600' 2>/dev/null
sleep 0.5
sc_live "working (spinner -> busy -> working)" "$sw" "$tmp/work.fp" working 0
tmux kill-session -t "$sw" 2>/dev/null

# CHANGED: idle box; establish the fingerprint, then ALTER the pane content. The second call
# sees changed=1 and reads working - an advancing idle pane is never stuck (the safe edge).
sch="sct_chg_$$"
tmux new-session -d -s "$sch" -x 80 -y 24 "printf '\xe2\x8f\xba all settled now.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5
sc_live "changed call 1 (assume alive, fp stored)" "$sch" "$tmp/chg.fp" working 0
tmux send-keys -t "$sch" -l 'ZZZ-ALTERED'
sleep 0.4
sc_live "changed call 2 (content altered -> changed=1 -> working, NOT stuck)" "$sch" "$tmp/chg.fp" working 0
tmux kill-session -t "$sch" 2>/dev/null

# STALLED (#28): a frozen-spinner turn. The real frozen-spinner fixture lives in timmy's own
# suite; here we drive timmy via a stub that exits 40, which proves the --pane GATHER path now
# recognises 'stalled' (pane_state 40 -> stalled) and routes it to stuck. Call 1 has no prior fp
# -> changed=1 -> working (safe direction even for a stalled read); call 2 is stable -> stuck.
stub40="$tmp/timmy-stub40"
printf '#!/bin/sh\nexit 40\n' >"$stub40"; chmod +x "$stub40"
sl="sct_stalled_$$"
tmux new-session -d -s "$sl" -x 80 -y 24 "printf '\xe2\x97\x8f Whirring\xe2\x80\xa6 (frozen)\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5
export MOSSY_TIMMY="$stub40"
sc_live "stalled call 1 (no prior fp -> assume alive)" "$sl" "$tmp/stalled.fp" working 0
sc_live "stalled call 2 (timmy exit 40, stable -> stalled -> stuck)" "$sl" "$tmp/stalled.fp" stuck 20
unset MOSSY_TIMMY
tmux kill-session -t "$sl" 2>/dev/null

# ============================================================================
# classify_turn_live - the liveness layer over the pure core.
#
# The pane is a 54-line alternate screen with no scrollback, so has_standby and the capture
# fingerprint are both read off a window that throws history away. Ground truth is the
# harness-written transcript. This layer states the precedence in code: liveness WINS, and
# classify_turn is the fallback for when no transcript can be resolved.
#
# Measured on 2026-07-30: 21 stuck-recovery wakes fired, all of them on a turn that had
# already ended, and only 3 of the 21 were the scroll-off shape. The other 18 are the
# parked-and-waiting case that liveness 'parked' now catches.
# ============================================================================
printf '\n== classify_turn_live (liveness wins, the scrape is the fallback) ==\n'

# "<liveness> <state> <has_standby> <changed> <expected>"
live_table=(
  # liveness working outranks an idle, stable, marker-less pane - the 40-minute turn and the
  # 529 ladder both arrive here, and both used to read stuck.
  "working idle 0 0 working"
  "working idle 1 0 working"
  "working stalled 0 0 working"

  # liveness parked maps to standby (exit 10), which is what heartbeat.sh already means by it.
  # This is the 18-of-21 case: a completed turn, legitimately waiting, NO marker on the pane.
  "parked idle 0 0 standby"
  "parked idle 1 0 standby"
  "parked stalled 0 0 standby"

  # liveness stuck is the wedged turn: open, silent past the threshold, rendering nothing.
  # It must NOT be softened by a marker that happens to be on screen.
  "stuck idle 0 0 stuck"
  "stuck idle 1 0 stuck"

  # no liveness resolved -> fall back to the existing pure core, byte-for-byte behaviour.
  "'' idle 1 0 standby"
  "'' idle 0 0 stuck"
  "'' idle 0 1 working"
  "'' busy 0 0 working"
  "'' stalled 0 0 stuck"
)
for row in "${live_table[@]}"; do
  read -r lv state hs ch want <<<"$row"
  [ "$lv" = "''" ] && lv=""
  got="$(classify_turn_live "$lv" "$state" "$hs" "$ch")"
  if [ "$got" = "$want" ]; then
    ok "$(printf 'liveness=%-8s %-8s standby=%s changed=%s -> %s' "${lv:-none}" "$state" "$hs" "$ch" "$got")"
  else
    no "$(printf 'liveness=%-8s %-8s standby=%s changed=%s -> %s (wanted %s)' "${lv:-none}" "$state" "$hs" "$ch" "$got" "$want")"
  fi
done

# has_standby must also be readable from the state FILE, not only from the capture, because a
# marker scrolls off a 54-line viewport. 220 real markers exist in shaun's transcripts; the
# pane showed none of them once a report followed. Three separator forms occur in the wild.
printf '\n== has_standby from the state file (the marker that scrolled off) ==\n'
sf="$tmp/shaun.state"
for line in \
  '1753906020 shaun standby STANDBY (context) - resume monitoring shirley' \
  '1753906020 shaun standby STANDBY - resume monitoring shirley' \
  '1753906020 shaun standby STANDBY — shirley on #366'; do
  printf '%s\n' "$line" >"$sf"
  if [ "$(standby_from_state "$sf")" = "1" ]; then
    ok "state file marker recognised: ${line#* shaun standby }"
  else
    no "state file marker NOT recognised: ${line#* shaun standby }"
  fi
done
printf '1753906500 shaun working timmy\n' >"$sf"
if [ "$(standby_from_state "$sf")" = "0" ]; then ok "a working state line is not a standby"; else no "a working state line read as standby"; fi
if [ "$(standby_from_state "$tmp/absent.state")" = "0" ]; then ok "a missing state file is not a standby"; else no "a missing state file read as standby"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
