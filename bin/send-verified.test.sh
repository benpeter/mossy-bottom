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

# ============================================================================
# ACCEPTANCE 5: a prompt that LANDED but whose agent is slow to first token reads as
# delivered.
#
# The idle/busy probe measures FIRST TOKEN latency and calls it delivery failure. Measured on
# 2026-07-30 across the live chain: first-token latency median 7.81s for bitzer, 9.09s for
# shaun, 12.14s for shirley, and 82.45s on the worst confirmed-landed prompt. 46 to 63 percent
# of LANDED prompts crossed the 8s window, which is the "roughly half FAILED to submit" the
# harness logged. There is not one genuinely failed submit in the corpus.
#
# The receiver's transcript is the honest signal: over 86 matched cross-transcript sends it
# grew within 3.09s of the Enter in 86 of 86 cases, median 0.59s. Claude Code appends the user
# record (or a queue-operation enqueue on a busy pane) at SUBMIT, before any token comes back.
#
# receiver_grew <pane> <baseline> is the new seam: 0 grew, 1 not yet, 2 unresolvable.
# submitted must accept 0 as proof, and fall back to the timmy poll only on 2.
# ============================================================================
printf '\n== acceptance 5: landed but slow to first token (transcript beats the idle probe) ==\n'

(
  # shellcheck source=/dev/null
  . "$sv"
  set +o pipefail
  # The 82.45s case: the pane never goes non-idle inside the poll window...
  # shellcheck disable=SC2329
  timmy_nonidle() { return 1; }
  # ...but the receiver's transcript grew 0.6s after the Enter.
  # shellcheck disable=SC2329
  receiver_grew() { return 0; }
  submitted DUMMY 0; rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'ok   - a grown receiver transcript proves delivery while the pane is still idle\n'
  else
    printf 'FAIL - grown transcript ignored: submitted returned %s, wanted 0\n' "$rc"
  fi
) | tee "$tmp/slow-token.out"
grep -q '^ok' "$tmp/slow-token.out" && pass=$((pass + 1)) || fail=$((fail + 1))

# A landed prompt must NOT be re-sent. The cost of getting this wrong is on the record: shaun
# to bitzer at 20:52:12 "THIRD DUPLICATE, and this one has a WORSE SHAP..." and again at
# 21:04:24 "FOURTH DUPLICATE, and it kills the obvious wor...".
(
  # shellcheck source=/dev/null
  . "$sv"
  set +o pipefail
  deliver_calls=0
  # shellcheck disable=SC2329
  deliver() { deliver_calls=$((deliver_calls + 1)); }
  # shellcheck disable=SC2329
  clear_input() { :; }
  # shellcheck disable=SC2329
  timmy_nonidle() { return 1; }   # slow first token, forever
  # shellcheck disable=SC2329
  receiver_grew() { return 0; }   # but it landed
  send_verified DUMMY 'x'; rc=$?
  if [ "$deliver_calls" -eq 1 ] && [ "$rc" -eq 0 ]; then
    printf 'ok   - a landed-but-slow prompt is delivered ONCE, never duplicated\n'
  else
    printf 'FAIL - duplicate send: %s deliveries rc %s, wanted 1 and 0\n' "$deliver_calls" "$rc"
  fi
) | tee "$tmp/no-dup.out"
grep -q '^ok' "$tmp/no-dup.out" && pass=$((pass + 1)) || fail=$((fail + 1))

# When the transcript cannot be resolved (exit 2) the helper must fall back to today's timmy
# probe rather than declaring either outcome. That keeps the change from ever being worse than
# what it replaces - the heartbeat itself has no transcript at all.
(
  # shellcheck source=/dev/null
  . "$sv"
  set +o pipefail
  # shellcheck disable=SC2329
  receiver_grew() { return 2; }   # unresolvable
  # shellcheck disable=SC2329
  timmy_nonidle() { return 0; }   # the old signal says the turn started
  submitted DUMMY 0; rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'ok   - unresolvable transcript falls back to the timmy probe\n'
  else
    printf 'FAIL - fallback broken: submitted returned %s, wanted 0\n' "$rc"
  fi
) | tee "$tmp/fallback.out"
grep -q '^ok' "$tmp/fallback.out" && pass=$((pass + 1)) || fail=$((fail + 1))

# A genuinely unsent prompt must still fail. Neither signal says it landed, so the retry and
# the nonzero exit both have to survive this change.
(
  # shellcheck source=/dev/null
  . "$sv"
  set +o pipefail
  # shellcheck disable=SC2329
  receiver_grew() { return 1; }   # transcript never grew
  # shellcheck disable=SC2329
  timmy_nonidle() { return 1; }   # pane never left idle
  submitted DUMMY 0; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'ok   - neither signal firing still reads as NOT submitted\n'
  else
    printf 'FAIL - a genuinely unsent prompt read as submitted\n'
  fi
) | tee "$tmp/genuine-fail.out"
grep -q '^ok' "$tmp/genuine-fail.out" && pass=$((pass + 1)) || fail=$((fail + 1))

# ============================================================================
# The receiver's cwd must come from the state dir, not from $PWD.
#
# Same bug as the one fixed in liveness-read: the heartbeat window inherits the HARNESS repo as its
# cwd (bin/barn.sh:674 has no -c) while the agents run in the TARGET repo. With $PWD as the default,
# the sweep looks in the wrong ~/.claude/projects directory, resolves nothing, and every send falls
# back to the timmy probe - so the delivery fix silently does not apply in production.
#
# Observed live 2026-07-31 00:56:21 on the running chain, which is what sent me looking:
#   send-verified: pane %3336 never appended after send + retry - prompt NOT submitted
#   heartbeat 00:56:21 | bitzer idle (%3336) -> nudge FAILED to submit after retry
# That is the ORIGINAL first-token false negative, still firing because the transcript path that
# was meant to replace it never resolved.
# ============================================================================
printf '\n== the receiver cwd comes from the state dir, not from $PWD ==\n'

(
  # shellcheck source=/dev/null
  . "$sv"
  set +o pipefail
  printf '  target mode: %s\n' "$(receiver_cwd '/x/target/.mossy')"
  printf '  dogfood mode: %s\n' "$(receiver_cwd '/x/harness')"
  printf '  no state dir: %s\n' "$(receiver_cwd '')"
) >"$tmp/cwd.out" 2>&1
if grep -q 'target mode: /x/target$' "$tmp/cwd.out"; then ok "target mode: <target>/.mossy -> <target>"; else no "target mode: $(grep 'target mode' "$tmp/cwd.out")"; fi
if grep -q 'dogfood mode: /x/harness$' "$tmp/cwd.out"; then ok "dogfood mode: a state dir with no /.mossy is left alone"; else no "dogfood mode: $(grep 'dogfood mode' "$tmp/cwd.out")"; fi
if grep -q "no state dir: $PWD\$" "$tmp/cwd.out"; then ok "no state dir -> \$PWD"; else no "no state dir: $(grep 'no state dir' "$tmp/cwd.out")"; fi

# End to end: a receiver whose transcript IS resolvable must be confirmed by its growth, from a
# deliberately wrong $PWD, with only MOSSY_STATE_DIR to go on.
e2e="$tmp/e2e"
sd="$e2e/.mossy"
proj="$tmp/e2eproj"
enc="$(printf '%s' "$e2e" | tr './' '--')"
sid='cccc3333-0000-0000-0000-00000000000c'
mkdir -p "$sd/liveness" "$proj/$enc"
printf 'shirley=%%9001\n' >"$sd/.barn-panes"
printf '{"type":"user","promptSource":"typed","sessionId":"%s","timestamp":"2026-07-31T01:00:00Z","message":{"role":"user","content":"YOU ARE SHIRLEY, the worker."}}\n' "$sid" >"$proj/$enc/$sid.jsonl"

(
  cd / || exit 1
  # export, not an assignment prefix: in default bash mode a prefix before `source` does not
  # persist, and the helper reads these at source time.
  export MOSSY_STATE_DIR="$sd" MOSSY_CLAUDE_PROJECTS="$proj"
  # shellcheck source=/dev/null
  . "$sv"
  set +o pipefail
  t="$(receiver_transcript '%9001')" && printf '  resolved: %s\n' "$t" || printf '  resolved: NOTHING\n'
) >"$tmp/e2e.out" 2>&1
if grep -q "resolved: $proj/$enc/$sid.jsonl" "$tmp/e2e.out"; then
  ok "a receiver's transcript resolves from the state dir with \$PWD wrong"
else
  no "receiver transcript did not resolve: $(cat "$tmp/e2e.out")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
