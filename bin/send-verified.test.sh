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


# --- the Copilot slash-command double Enter (one-harness step 5) -------------------------------
# Typing '/' in Copilot opens a filter palette. The FIRST Enter picks the highlighted entry out
# of it; the SECOND submits. One Enter leaves the command sitting in the composer, which reads
# exactly like a send that silently failed - so every slash command a Copilot-driven driver
# sends would look delivered and do nothing.
#
# The second Enter must NOT fire on a Claude Code pane, where the command already submitted and
# a stray Enter starts an empty turn. So the decision needs BOTH facts: the pane speaks Copilot,
# and the text is a slash command. These drive the predicate seam directly, because "how many
# Enters were sent" is not observable from a fixture pane.
printf '\n== copilot slash-command double Enter ==\n'
# shellcheck source=/dev/null
. "$sv" >/dev/null 2>&1 || true

cop_chrome=' / commands \xc2\xb7 ? help \xc2\xb7 tab next tab                          GPT-5.6 Sol\n /repo                                          Session: 15.1 AIC used\n'
cc_chrome='  ~/x | Opus 4.8 | Context: 41%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle)\n'

new_pane sv_cop "printf '${cop_chrome}'; sleep 600"
cop_pane="$PANE"
new_pane sv_cc "printf '${cc_chrome}'; sleep 600"
cc_pane="$PANE"
sleep 0.4

if is_copilot_pane "$cop_pane"; then ok "a Copilot pane is recognised"; else no "a Copilot pane is recognised"; fi
if is_copilot_pane "$cc_pane"; then no "a Claude Code pane is NOT read as Copilot"; else ok "a Claude Code pane is NOT read as Copilot"; fi

if needs_double_enter "$cop_pane" '/compact'; then ok "copilot + slash command -> two Enters"; else no "copilot + slash command -> two Enters"; fi
if needs_double_enter "$cop_pane" 'build the header'; then no "copilot + PROSE -> one Enter"; else ok "copilot + PROSE -> one Enter"; fi
if needs_double_enter "$cc_pane" '/compact'; then no "claude + slash command -> one Enter (a stray Enter starts an empty turn)"; else ok "claude + slash command -> one Enter (a stray Enter starts an empty turn)"; fi
if needs_double_enter "$cc_pane" 'build the header'; then no "claude + prose -> one Enter"; else ok "claude + prose -> one Enter"; fi

# A pane that cannot be read is not Copilot: guessing wrong here sends a stray Enter into a
# driver's pane, and an unexplained empty turn is worse than a slash command that needs a nudge.
if is_copilot_pane 'no_such_pane_'"$$"; then no "an unreadable pane is not assumed to be Copilot"; else ok "an unreadable pane is not assumed to be Copilot"; fi


printf '\n== a BUSY copilot pane enqueues on ctrl+enter, it does not submit on Enter ==\n'
# 2026-07-28: four messages were lost to this in one morning and every one looked delivered.
# Plain Enter into a running Copilot turn leaves the text in the composer indefinitely; the
# pane advertises the real key in its own busy footer as 'ctrl+enter enqueue'. An idle pane
# still takes a plain Enter, and Claude Code takes one in BOTH states, so all three arms matter.
cop_busy_chrome=' ~/x [\xe2\x8e\x87 main]                          Session: 15.1 AIC used\n \xe2\x97\x89 Working \xc2\xb7 7.2 KiB esc interrupt \xc2\xb7 ctrl+enter enqueue\n'
cc_busy_chrome='  ~/x | Opus 4.8 | Context: 41%%\n  \xe2\x9c\xbb Brewing... (esc to interrupt)\n'

new_pane sv_cop_busy "printf '${cop_busy_chrome}'; sleep 600"
cop_busy="$PANE"
new_pane sv_cc_busy "printf '${cc_busy_chrome}'; sleep 600"
cc_busy="$PANE"
sleep 0.4

# A missing function returns 127, which is falsy, so every "must be false" assertion below
# would PASS for the wrong reason. Assert the seams exist first, or the red is a lie.
for _fn in pane_is_busy needs_enqueue; do
  if declare -F "$_fn" >/dev/null 2>&1; then ok "seam $_fn exists"; else no "seam $_fn exists"; fi
done

if pane_is_busy "$cop_busy"; then ok "a busy pane is read as busy"; else no "a busy pane is read as busy"; fi
if pane_is_busy "$cop_pane"; then no "an IDLE copilot pane is not read as busy"; else ok "an IDLE copilot pane is not read as busy"; fi

if needs_enqueue "$cop_busy"; then ok "busy copilot -> ctrl+enter enqueue"; else no "busy copilot -> ctrl+enter enqueue"; fi
if needs_enqueue "$cop_pane"; then no "IDLE copilot -> plain Enter"; else ok "IDLE copilot -> plain Enter"; fi
if needs_enqueue "$cc_busy"; then no "busy Claude Code -> plain Enter, it queues on its own"; else ok "busy Claude Code -> plain Enter, it queues on its own"; fi
if needs_enqueue 'no_such_pane_'"$$"; then no "an unreadable pane never gets ctrl+enter"; else ok "an unreadable pane never gets ctrl+enter"; fi

# deliver() must actually SEND the sequence, not merely decide to. Spy on tmux so the assertion
# is the bytes that leave, which is the thing that was wrong in production.
#
# Two traps this spy has to avoid, both hit on the first attempt. It must PASS THROUGH the
# stdout of capture-pane, or needs_enqueue reads an empty pane and never fires. And its verdict
# has to leave the subshell through a file, because ok/no there would increment a counter the
# parent never sees, which reports 0 failed while printing FAIL.
printf '\n== deliver sends the ctrl+enter bytes to a busy copilot pane ==\n'
spy_out="$(mktemp)"
spy_deliver() { # spy_deliver <pane> <text> -> writes the sent args to $spy_out
  ( : >"$spy_out"
    # shellcheck disable=SC2329
    tmux() {
      case "$1" in send-keys) printf '|%s' "$*" >>"$spy_out" ;; esac
      command tmux "$@"
    }
    deliver "$1" "$2" >/dev/null 2>&1
  )
}

spy_deliver "$cop_busy" 'some prose'
sent="$(cat "$spy_out")"
case "$sent" in
  *'-H 1b 5b 31 33 3b 35 75'*) ok "busy copilot: deliver sends ESC[13;5u" ;;
  *) no "busy copilot: deliver sends ESC[13;5u (sent: $sent)" ;;
esac
case "$sent" in
  *'send-keys -t '*' Enter'*) no "busy copilot: deliver must not ALSO send a plain Enter (sent: $sent)" ;;
  *) ok "busy copilot: deliver sends no plain Enter" ;;
esac

spy_deliver "$cop_pane" 'some prose'
sent="$(cat "$spy_out")"
case "$sent" in
  *'-H 1b'*) no "IDLE copilot: deliver must NOT send ctrl+enter (sent: $sent)" ;;
  *Enter*) ok "IDLE copilot: deliver sends a plain Enter" ;;
  *) no "IDLE copilot: deliver sends a plain Enter (sent: $sent)" ;;
esac

spy_deliver "$cc_busy" 'some prose'
sent="$(cat "$spy_out")"
case "$sent" in
  *'-H 1b'*) no "busy Claude Code: deliver must NOT send ctrl+enter (sent: $sent)" ;;
  *Enter*) ok "busy Claude Code: deliver sends a plain Enter" ;;
  *) no "busy Claude Code: deliver sends a plain Enter (sent: $sent)" ;;
esac
rm -f "$spy_out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
