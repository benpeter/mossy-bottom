#!/usr/bin/env bash
#
# send-verified.sh - deliver a prompt into a tmux pane AND confirm it actually submitted.
# Vanilla bash + tmux + timmy. No third-party dependencies.
#
# Why this exists (Issue #31, the 06:39 lesson, run 3): a long prompt sent with `send-keys -l`
# followed by an immediate `Enter` RACES - the Enter can land before the literal text finishes
# arriving, so the whole prompt sits BUFFERED, UNSENT, in the input box. The pane then looks
# like a frozen spinner and costs ~10min of misdiagnosis. barn.sh's send_prompt mitigates the
# race with a fixed settle sleep, but never CONFIRMS the submit took. This helper closes that
# gap: type, Enter, then ask timmy whether the turn actually started. submitted -> the pane goes
# BUSY; failed -> it stays IDLE with the prompt still in the box. On a failed submit it clears
# the input and retries ONCE, then exits nonzero so the caller knows delivery failed rather than
# silently driving a pane that never received its prompt.
#
# The submitted signal is the RECEIVER'S TRANSCRIPT GROWING, not timmy's busy/idle read. Claude
# Code appends the receiver's record at SUBMIT, before any token comes back: a user record on an
# idle pane, a queue-operation enqueue on a busy one. Measured over 86 matched cross-transcript
# sends on 2026-07-30, the receiver's file grew within 3.09s of the Enter in 86 of 86 cases,
# median 0.59s.
#
# timmy's non-idle read is kept as the FALLBACK for when a receiver's transcript cannot be
# resolved, because it measures the wrong thing: it asks whether a token has come back. Measured
# first-token latency was a median of 7.81s for bitzer, 9.09s for shaun and 12.14s for shirley,
# and 82.45s on the worst confirmed-landed prompt, so 46 to 63 percent of prompts that HAD landed
# crossed the old window. That is the "roughly half FAILED to submit" the heartbeat logged, and
# the corpus holds no genuinely failed submit at all. The cost was duplicate hands, which shaun
# logged as "THIRD DUPLICATE" at 20:52:12 and "FOURTH DUPLICATE" at 21:04:24.
#
# CLI: send-verified.sh <pane> <text>
#   exit 0   the prompt submitted (timmy saw the pane go non-idle within the poll window)
#   exit 1   delivery FAILED - the pane stayed idle through the initial send AND the one retry
#   exit 64  usage error
#
# Environment:
#   MOSSY_TIMMY    path to the timmy classifier (default: <script>/../timmy/bin/timmy)
#   SV_POLLS       timmy polls per delivery attempt before giving up (default: 4)
#   SV_SETTLE      seconds to wait between the literal text and the Enter (default: 0.5)
#   TIMMY_INTERVAL forwarded to timmy - seconds between its two snapshots (default: timmy's 2)
#
# tva
set -uo pipefail

readonly EXIT_OK=0
readonly EXIT_UNSENT=1
readonly EXIT_USAGE=64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMMY="${MOSSY_TIMMY:-${SCRIPT_DIR}/../timmy/bin/timmy}"
SV_POLLS="${SV_POLLS:-4}"
SV_SETTLE="${SV_SETTLE:-0.5}"

# The transcript-grow confirmation. Measured worst case over 86 real sends was 3.09s, median
# 0.59s, so 10 polls at 0.5s allows 5s - margin over everything observed.
SV_GROW_POLLS="${SV_GROW_POLLS:-10}"
SV_GROW_SLEEP="${SV_GROW_SLEEP:-0.5}"
LIVENESS_READ="${MOSSY_LIVENESS_READ:-${SCRIPT_DIR}/liveness-read.sh}"
SV_STATE_DIR="${MOSSY_STATE_DIR:-}"
SV_AGENT_CWD="${MOSSY_AGENT_CWD:-${PWD}}"

die() { printf 'send-verified: %s\n' "$1" >&2; exit "${EXIT_USAGE}"; }

usage() {
  cat <<'EOF'
Usage: send-verified.sh <pane> <text>

Deliver <text> into the tmux <pane> and confirm the prompt actually submitted, using
timmy's busy/idle classification as the submitted signal. Types the literal text, sends
Enter, then polls timmy: a non-idle pane means the turn started (success); an idle pane
means the submit did not take. On a failed submit the input is cleared and the send is
retried ONCE; a second failure exits nonzero.

Arguments:
  <pane>   tmux pane/target to drive (e.g. %2, or a session name)
  <text>   the literal prompt text to deliver

Exit codes:
  0   submitted (pane went non-idle within the poll window)
  1   delivery failed (pane stayed idle through the send and the retry)
  64  usage error

Environment:
  MOSSY_TIMMY     path to timmy (default: <script>/../timmy/bin/timmy)
  SV_POLLS        timmy polls per delivery attempt (default: 4)
  SV_SETTLE       seconds between the literal text and the Enter (default: 0.5)
  TIMMY_INTERVAL  forwarded to timmy (seconds between its two snapshots)
EOF
}

# deliver <pane> <text> - the smoke-test send rule (barn.sh send_prompt): literal text, a
# settle, then a SEPARATE Enter. The settle is the first line of defence against the 06:39
# race; the poll that follows is the confirmation that closes the gap the settle alone left.
deliver() {
  local pane="$1" text="$2"
  tmux send-keys -l -t "${pane}" -- "${text}"
  sleep "${SV_SETTLE}"
  tmux send-keys -t "${pane}" Enter
}

# clear_input <pane> - empty the input box before a retry, so a partially-buffered first
# attempt cannot concatenate with the retry into a garbled prompt. C-u kills the line; the
# BSpace burst is belt-and-suspenders for any editor state C-u does not cover.
clear_input() {
  local pane="$1" i
  tmux send-keys -t "${pane}" C-u
  for ((i = 0; i < 64; i++)); do
    tmux send-keys -t "${pane}" BSpace
  done
  tmux send-keys -t "${pane}" C-u
}

# timmy_nonidle <pane> - the ORIGINAL signal, kept as the fallback. Poll timmy up to SV_POLLS
# times; return 0 as soon as it reports a NON-IDLE state (busy/waiting/question/stalled, exit
# 10/20/30/40). Bounded by SV_POLLS, so this always returns.
#
# It is only a fallback now because it measures the wrong thing. It asks "has a token come back
# yet", and on 2026-07-30 the measured first-token latency was a median of 7.81s for bitzer,
# 9.09s for shaun and 12.14s for shirley, with 82.45s on the worst confirmed-landed prompt. So
# 46 to 63 percent of prompts that HAD landed crossed this window, which is the "roughly half
# FAILED to submit" the heartbeat logged. There is not one genuinely failed submit in the corpus.
timmy_nonidle() {
  local pane="$1" i code
  for ((i = 0; i < SV_POLLS; i++)); do
    "${TIMMY}" --pane "${pane}" >/dev/null 2>&1
    code=$?
    case "${code}" in
      10 | 20 | 30 | 40) return 0 ;; # non-idle -> a token came back
      *) : ;;                        # idle (0) or inconclusive -> keep polling
    esac
  done
  return 1
}

# receiver_grew <pane> <baseline-mtime> - did the RECEIVER's transcript grow since <baseline>?
# Returns 0 grew, 1 not yet, 2 unresolvable.
#
# This is the honest delivery signal. Claude Code appends the receiver's record at SUBMIT, before
# any token comes back: a user record on an idle pane, or a queue-operation enqueue on a busy
# one. Measured over 86 matched cross-transcript sends, the receiver's file grew within 3.09s of
# the Enter in 86 of 86 cases, median 0.59s. SV_GROW_WAIT allows 5s, margin over everything
# observed.
#
# 2 (unresolvable) matters: the heartbeat has no transcript of its own and a receiver's session
# id may not be recorded yet, so the caller must fall back rather than guess. That keeps this
# change from ever being worse than the probe it replaces.
receiver_grew() {
  local pane="$1" baseline="$2" t i cur
  t="$(receiver_transcript "${pane}")" || return 2
  [ -n "${t}" ] || return 2
  for ((i = 0; i < SV_GROW_POLLS; i++)); do
    cur="$(stat -f %m "${t}" 2>/dev/null || stat -c %Y "${t}" 2>/dev/null || true)"
    [ -n "${cur}" ] || return 2
    [ "${cur}" -gt "${baseline}" ] 2>/dev/null && return 0
    sleep "${SV_GROW_SLEEP}"
  done
  return 1
}

# receiver_transcript <pane> - echo the path to the transcript of whatever agent owns <pane>, or
# return 1. Resolved through the pane's state file, whose last line carries the agent's current
# session id; that indirection is deliberate, because /clear mints a new transcript file and a
# cached path would go stale (shirley acquired six in 3.5 hours on 2026-07-30).
receiver_transcript() {
  local pane="$1" sf sid
  sf="${SV_STATE_DIR:+${SV_STATE_DIR}/liveness/${pane}.state}"
  [ -n "${sf}" ] && [ -s "${sf}" ] || return 1
  sid="$(tail -n 1 "${sf}" 2>/dev/null | awk '$4 ~ /^[0-9a-f]{8}-/ {print $4}')"
  [ -n "${sid}" ] || return 1
  [ -x "${LIVENESS_READ}" ] || return 1
  # shellcheck source=/dev/null
  ( . "${LIVENESS_READ}"; transcript_for "${MOSSY_CLAUDE_PROJECTS:-${HOME}/.claude/projects}" \
      "${SV_AGENT_CWD}" "${sid}" )
}

# transcript_baseline <pane> - the receiver's transcript mtime BEFORE the Enter, so a grow can be
# detected. 0 when unresolvable, which makes any real mtime count as growth; that is the safe
# direction here, because the fallback still has to agree before we call a send failed.
transcript_baseline() {
  local t
  t="$(receiver_transcript "$1" 2>/dev/null)" || { printf '0'; return 0; }
  stat -f %m "${t}" 2>/dev/null || stat -c %Y "${t}" 2>/dev/null || printf '0'
}

# submitted <pane> <baseline> - did the prompt land? The receiver's transcript growing is proof;
# an unresolvable transcript falls back to the old first-token probe. Both failing means unsent.
submitted() {
  local pane="$1" baseline="${2:-0}"
  receiver_grew "${pane}" "${baseline}"
  case "$?" in
    0) return 0 ;;                          # the receiver's file grew - it landed
    2) timmy_nonidle "${pane}"; return $? ;; # cannot resolve - fall back to the old probe
  esac
  return 1
}

# send_verified <pane> <text> - deliver, confirm; on a failed submit clear and retry ONCE,
# then give up nonzero. The seam the test drives directly.
send_verified() {
  local pane="$1" text="$2" baseline
  baseline="$(transcript_baseline "${pane}")"
  deliver "${pane}" "${text}"
  if submitted "${pane}" "${baseline}"; then
    return "${EXIT_OK}"
  fi
  # A retry re-types the prompt, so a landed-but-slow prompt must never reach here: shaun logged
  # the cost as "THIRD DUPLICATE" at 20:52:12 and "FOURTH DUPLICATE" at 21:04:24 on 2026-07-30.
  clear_input "${pane}"
  baseline="$(transcript_baseline "${pane}")"
  deliver "${pane}" "${text}"
  if submitted "${pane}" "${baseline}"; then
    return "${EXIT_OK}"
  fi
  printf 'send-verified: pane %s never appended after send + retry - prompt NOT submitted\n' "${pane}" >&2
  return "${EXIT_UNSENT}"
}

main() {
  case "${1:-}" in
    -h | --help) usage; return 0 ;;
  esac
  [ $# -eq 2 ] || die "usage: send-verified.sh <pane> <text>"
  local pane="$1" text="$2"
  [ -n "${pane}" ] || die "<pane> must not be empty"
  command -v tmux >/dev/null 2>&1 || die "tmux not found (required)"
  [ -x "${TIMMY}" ] || die "timmy not found or not executable at '${TIMMY}' (set MOSSY_TIMMY)"
  send_verified "${pane}" "${text}"
}

# Run main only when executed, not when sourced - so the test can source this file and drive
# send_verified / submitted directly. The same seam barn.sh / timmy / stuck-check use.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
