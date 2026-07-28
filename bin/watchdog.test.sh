#!/usr/bin/env bash
# watchdog.test.sh - hermetic tests for bin/watchdog.sh. Pure arithmetic on flags: no
# usage read, no network, no panes.
#
# The thresholds are the point of this suite. The Farmer set both to 95 (2026-07-29): the
# run pauses only when a window is nearly spent, not at the earlier 80 and 85, which
# stopped work with a fifth of the 5-hour window still unused.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
wd="$here/watchdog.sh"

pass=0
fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# case <want-code> <label> <args...> - run watchdog with args, assert the exit code.
# 0 = CLEAR, 10 = PAUSE.
case_wd() {
  local want="$1" label="$2"; shift 2
  local out code
  out="$("$wd" "$@" 2>&1)"
  code=$?
  if [ "$code" -eq "$want" ]; then
    ok "$label"
  else
    no "$label (exit $code want $want; output '$out')"
  fi
}

# --- The defaults. Both windows pause at 95 and not before. ---

case_wd 0 "5h 94 is CLEAR under the default" --5h 94 --weekly 10
case_wd 10 "5h 95 PAUSES on the default (inclusive)" --5h 95 --weekly 10
case_wd 0 "weekly 94 is CLEAR under the default" --5h 10 --weekly 94
case_wd 10 "weekly 95 PAUSES on the default (inclusive)" --5h 10 --weekly 95

# The levels the old defaults tripped on must now keep working. This is the change: at
# 5h 82 and weekly 86 the run used to stop with most of both windows still available.
case_wd 0 "5h 82 keeps working (used to pause at the old 80)" --5h 82 --weekly 10
case_wd 0 "weekly 86 keeps working (used to pause at the old 85)" --5h 10 --weekly 86
case_wd 0 "5h 94 and weekly 94 together are still CLEAR" --5h 94 --weekly 94

# --- A full window still pauses, and the signal still names the window. ---

case_wd 10 "5h 100 pauses" --5h 100 --weekly 0
case_wd 10 "weekly 100 pauses" --5h 0 --weekly 100

out="$("$wd" --5h 96 --weekly 97 2>&1)"
if grep -qi '5h' <<<"$out" && grep -qi 'week' <<<"$out"; then
  ok "both windows over: the signal names both"
else
  no "both windows over: the signal names both (got '$out')"
fi

# --- The knobs still override, so a run can be made cautious again without an edit. ---

case_wd 10 "--5h-threshold overrides the default down" --5h 50 --weekly 0 --5h-threshold 45
case_wd 10 "--weekly-threshold overrides the default down" --5h 0 --weekly 50 --weekly-threshold 45

export MOSSY_WD_5H=45
case_wd 10 "MOSSY_WD_5H overrides the default down" --5h 50 --weekly 0
case_wd 0 "a flag beats the env var" --5h 50 --weekly 0 --5h-threshold 99
unset MOSSY_WD_5H

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
