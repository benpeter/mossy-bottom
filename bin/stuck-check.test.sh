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

# usage errors are exit 64, never a verdict
"$sc" --state idle --has-standby 0 >/dev/null 2>&1
code=$?
if [ "$code" -eq 64 ]; then ok "CLI missing --changed -> usage error 64"; else no "CLI missing --changed -> usage error 64 (got $code)"; fi
"$sc" --state bogus --has-standby 0 --changed 0 >/dev/null 2>&1
code=$?
if [ "$code" -eq 64 ]; then ok "CLI invalid --state -> usage error 64"; else no "CLI invalid --state -> usage error 64 (got $code)"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
