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
# The submitted/not-submitted signal is timmy's busy/idle classification - NOT a bespoke
# 'box has text' parser. A prompt that leaves the input box starts a turn (timmy reads a
# non-idle state); a prompt that never submitted leaves a settled idle box (timmy reads idle).
# Reusing timmy keeps the one classifier authoritative and avoids a second, drifting parser.
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

# submitted <pane> - poll timmy up to SV_POLLS times; return 0 as soon as timmy reports a
# NON-IDLE state (busy/waiting/question/stalled, exit 10/20/30/40) - the turn started, so the
# prompt left the box. timmy's idle (exit 0) means the prompt is still sitting unsent, so we
# poll again. A read error / usage code is inconclusive -> also poll again. Bounded by SV_POLLS
# (each timmy call self-terminates after two snapshots), so this always returns.
submitted() {
  local pane="$1" i code
  for ((i = 0; i < SV_POLLS; i++)); do
    "${TIMMY}" --pane "${pane}" >/dev/null 2>&1
    code=$?
    case "${code}" in
      10 | 20 | 30 | 40) return 0 ;; # non-idle -> the turn started, prompt submitted
      *) : ;;                        # idle (0) or inconclusive -> keep polling
    esac
  done
  return 1
}

# send_verified <pane> <text> - deliver, confirm; on a failed submit clear and retry ONCE,
# then give up nonzero. The seam the test drives directly.
send_verified() {
  local pane="$1" text="$2"
  deliver "${pane}" "${text}"
  if submitted "${pane}"; then
    return "${EXIT_OK}"
  fi
  clear_input "${pane}"
  deliver "${pane}" "${text}"
  if submitted "${pane}"; then
    return "${EXIT_OK}"
  fi
  printf 'send-verified: pane %s stayed idle after send + retry - prompt NOT submitted\n' "${pane}" >&2
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
