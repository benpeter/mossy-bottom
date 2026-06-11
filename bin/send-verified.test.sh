#!/usr/bin/env bash
# send-verified.test.sh - hermetic, launch-free tests for bin/send-verified.sh (Issue #31).
# No claude: the fixtures are plain bash panes and the real timmy classifier reads them. We
# drive the helper end-to-end (deliver -> Enter -> poll timmy) against:
#   * a SUCCESS pane that is blocked on `read` (static -> idle) and, once it receives the line,
#     loops emitting changing output (-> busy). send-verified must detect the busy transition
#     and exit 0.
#   * a FAILURE pane that ignores stdin entirely (`sleep`, static -> idle forever). send-verified
#     must retry once and then exit nonzero with a clear "not submitted" message.
# Plus the usage guards. Every poll is bounded (short TIMMY_INTERVAL, small SV_POLLS), so the
# suite always terminates; all panes are torn down on exit.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
sv="$here/send-verified.sh"

# Fast + bounded: short timmy snapshot interval and few polls keep each attempt sub-second
# without changing the helper's logic. The helper forwards TIMMY_INTERVAL to timmy.
export TIMMY_INTERVAL="${TIMMY_INTERVAL:-0.3}"
export SV_POLLS="${SV_POLLS:-3}"
export SV_SETTLE="${SV_SETTLE:-0.2}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/send-verified-test-XXXXXX")"
sessions=()
cleanup() {
  local s
  if [ "${#sessions[@]}" -gt 0 ]; then
    for s in "${sessions[@]}"; do tmux kill-session -t "$s" 2>/dev/null; done
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

pass=0
fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# new_pane <name> <command> - start a detached throwaway tmux session running <command> and
# register it for teardown. Sets the global PANE to the session name. Called DIRECTLY (never in
# $(...)): a command-substitution subshell would isolate the `sessions+=` append and leak panes.
new_pane() {
  local name="$1" cmd="$2"
  PANE="${name}_$$"
  tmux new-session -d -s "$PANE" -x 80 -y 24 "$cmd" 2>/dev/null
  sessions+=("$PANE")
}

printf '== send-verified end-to-end (real tmux panes, real timmy, no claude) ==\n'

# --- SUCCESS: a pane that goes idle -> busy on receiving input -------------------------------
# Blocked on `read` => static screen => timmy idle. Once send-verified delivers the line and
# Enter, the read completes and the loop emits ever-changing output => timmy busy. The helper
# must see the busy transition and report success.
# shellcheck disable=SC2016  # $RANDOM must expand in the FIXTURE shell tmux launches, not here
new_pane sv_ok 'read x; while :; do printf "tick %s\n" "$RANDOM"; sleep 0.05; done'; ok_pane="$PANE"
sleep 0.5
out="$("$sv" "$ok_pane" 'hello from send-verified' 2>&1)"; code=$?
if [ "$code" -eq 0 ]; then ok "success path: idle->busy pane accepts the prompt (exit 0)"; else no "success path: expected exit 0, got $code (out: $out)"; fi

# --- FAILURE: a pane that ignores input ------------------------------------------------------
# `sleep` never reads stdin, so the screen stays static => timmy idle through the initial send
# AND the retry. send-verified must exit nonzero (delivery failed), not hang or falsely succeed.
new_pane sv_bad 'sleep 600'; bad_pane="$PANE"
sleep 0.5
out="$("$sv" "$bad_pane" 'this will never submit' 2>&1)"; code=$?
if [ "$code" -ne 0 ]; then ok "failure path: input-ignoring pane -> nonzero (exit $code)"; else no "failure path: expected nonzero, got 0 (out: $out)"; fi
if printf '%s' "$out" | grep -q 'NOT submitted'; then ok "failure path: prints a clear 'NOT submitted' message"; else no "failure path: missing the clear failure message (out: $out)"; fi
if [ "$code" -eq 1 ]; then ok "failure path: exits with the delivery-failed code 1"; else no "failure path: expected exit 1, got $code"; fi

# --- the FAILURE pane was genuinely retried, not given up on after one send -------------------
# Sourced seam: spy on deliver() to count attempts. A failed submit must deliver TWICE (initial
# + one retry) before declaring failure - the retry-once contract.
(
  # shellcheck source=/dev/null
  . "$sv"
  set +o pipefail
  deliver_calls=0
  # These stubs override the sourced functions; send_verified invokes them indirectly (SC2329).
  # shellcheck disable=SC2329
  deliver() { deliver_calls=$((deliver_calls + 1)); }   # stub: count, send nothing
  # shellcheck disable=SC2329
  clear_input() { :; }                                   # stub: no-op
  # shellcheck disable=SC2329
  submitted() { return 1; }                              # stub: always "still idle"
  send_verified DUMMY 'x'; rc=$?
  if [ "$deliver_calls" -eq 2 ] && [ "$rc" -eq 1 ]; then
    printf 'ok   - retry-once: a failed submit delivers exactly twice then fails (rc 1)\n'
  else
    printf 'FAIL - retry-once: expected 2 deliveries + rc 1, got %s deliveries rc %s\n' "$deliver_calls" "$rc"
  fi
) | tee "$tmp/retry.out"
grep -q '^ok' "$tmp/retry.out" && pass=$((pass + 1)) || fail=$((fail + 1))

# --- a submit that takes on the FIRST poll does not retry -------------------------------------
(
  # shellcheck source=/dev/null
  . "$sv"
  set +o pipefail
  deliver_calls=0
  clear_calls=0
  # Stubs overriding the sourced functions, invoked indirectly via send_verified (SC2329).
  # Run send_verified DIRECTLY (not in $(...)), else its subshell would isolate the counters.
  # shellcheck disable=SC2329
  deliver() { deliver_calls=$((deliver_calls + 1)); }
  # shellcheck disable=SC2329
  clear_input() { clear_calls=$((clear_calls + 1)); }    # must NOT be called on first-poll success
  # shellcheck disable=SC2329
  submitted() { return 0; }                              # stub: submitted immediately
  send_verified DUMMY 'x'; rc=$?
  if [ "$deliver_calls" -eq 1 ] && [ "$clear_calls" -eq 0 ] && [ "$rc" -eq 0 ]; then
    printf 'ok   - first-poll success delivers once, no retry/clear, exit 0\n'
  else
    printf 'FAIL - first-poll success: got %s deliveries %s clears rc %s\n' "$deliver_calls" "$clear_calls" "$rc"
  fi
) | tee "$tmp/once.out"
grep -q '^ok' "$tmp/once.out" && pass=$((pass + 1)) || fail=$((fail + 1))

# --- usage guards ----------------------------------------------------------------------------
printf '\n== usage guards ==\n'
"$sv" >/dev/null 2>&1; code=$?
if [ "$code" -eq 64 ]; then ok "no args -> usage error 64"; else no "no args -> expected 64, got $code"; fi

"$sv" only-one-arg >/dev/null 2>&1; code=$?
if [ "$code" -eq 64 ]; then ok "one arg -> usage error 64"; else no "one arg -> expected 64, got $code"; fi

MOSSY_TIMMY="$tmp/does-not-exist" "$sv" some-pane 'text' >/dev/null 2>&1; code=$?
if [ "$code" -eq 64 ]; then ok "missing timmy -> usage error 64"; else no "missing timmy -> expected 64, got $code"; fi

"$sv" --help >/dev/null 2>&1; code=$?
if [ "$code" -eq 0 ]; then ok "--help -> exit 0"; else no "--help -> expected 0, got $code"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
