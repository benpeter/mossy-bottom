#!/usr/bin/env bash
#
# stuck-check.sh - decide whether a deference-chain pane is working, legitimately paused,
# or STUCK on a dead turn (Issue #20). This slice is the PURE decision core only: it reads
# no tmux, calls no timmy, and wires into no heartbeat - those are later slices. It takes
# three EXPLICIT inputs and echoes one verdict word, so the policy is testable in isolation.
#
# The dead turn this exists to catch: a malformed tool call can freeze a Claude pane mid-turn
# with NO spinner and NO STANDBY marker - it reads idle and never advances, so neither the
# usage gate nor bitzer's STANDBY-wake path ever touches it and the chain silently stalls.
#
# classify_turn <state> <has_standby> <changed> -> one of:
#   working  state is busy|waiting|question, OR changed=1 - the pane is alive / advancing.
#   standby  state=idle AND changed=0 AND has_standby=1 - a legitimate paused turn; bitzer's
#            normal STANDBY-wake handles it, it is NOT a stuck-nudge target.
#   stuck    state=idle AND changed=0 AND has_standby=0 - the dead, frozen turn.
#
# The function TRUSTS 'changed' as given. The await-vs-stuck distinction (a legitimately
# backgrounded await advances its pane within a heartbeat interval, so changed=1) is carried
# by HOW 'changed' is sampled - that sampling is a LATER slice, not this one.
#
# CLI: stuck-check.sh --state <idle|busy|waiting|question> --has-standby <0|1> --changed <0|1>
# prints the verdict and exits 0 (working) / 10 (standby) / 20 (stuck); 64 on a usage error.
#
# tva
set -uo pipefail

readonly EXIT_WORKING=0
readonly EXIT_STANDBY=10
readonly EXIT_STUCK=20
readonly EXIT_USAGE=64

die() { printf 'stuck-check: %s\n' "$1" >&2; exit "${EXIT_USAGE}"; }

usage() {
  cat <<'EOF'
Usage: stuck-check.sh --state <idle|busy|waiting|question> --has-standby <0|1> --changed <0|1>

Decide whether a pane is working, legitimately paused (standby), or stuck on a dead turn.

Inputs:
  --state <s>        the pane's classified state (idle|busy|waiting|question)
  --has-standby <b>  1 if the pane shows a STANDBY marker, else 0
  --changed <b>      1 if the pane advanced within the sampling interval, else 0

Verdict (printed) and exit code:
  working  0   state is busy|waiting|question, OR changed=1 (alive / advancing)
  standby 10   idle AND changed=0 AND has_standby=1 (legit paused turn)
  stuck   20   idle AND changed=0 AND has_standby=0 (dead, frozen turn)
  usage error 64
EOF
}

# classify_turn <state> <has_standby> <changed> - PURE: echo the verdict word for the given
# inputs, total over the documented domain (state in {idle,busy,waiting,question}; the two
# flags in {0,1}). No side effects, no I/O beyond the echo - this is the seam the test drives.
classify_turn() {
  local state="$1" has_standby="$2" changed="$3"
  # Alive / advancing wins first: any non-idle state, or a pane that moved this interval.
  if [ "${state}" != "idle" ] || [ "${changed}" = "1" ]; then
    printf 'working\n'
    return 0
  fi
  # From here: state=idle AND changed=0. A STANDBY marker means a legit pause, not a stall.
  if [ "${has_standby}" = "1" ]; then
    printf 'standby\n'
  else
    printf 'stuck\n'
  fi
}

main() {
  local state="" has_standby="" changed=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) shift; [ $# -gt 0 ] || die "--state needs a value"; state="$1" ;;
      --has-standby) shift; [ $# -gt 0 ] || die "--has-standby needs a value"; has_standby="$1" ;;
      --changed) shift; [ $# -gt 0 ] || die "--changed needs a value"; changed="$1" ;;
      -h | --help) usage; return 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done

  [ -n "${state}" ] || die "--state is required (idle|busy|waiting|question)"
  [ -n "${has_standby}" ] || die "--has-standby is required (0|1)"
  [ -n "${changed}" ] || die "--changed is required (0|1)"
  case "${state}" in idle | busy | waiting | question) ;; *) die "invalid --state '${state}' (idle|busy|waiting|question)" ;; esac
  case "${has_standby}" in 0 | 1) ;; *) die "invalid --has-standby '${has_standby}' (0|1)" ;; esac
  case "${changed}" in 0 | 1) ;; *) die "invalid --changed '${changed}' (0|1)" ;; esac

  local verdict
  verdict="$(classify_turn "${state}" "${has_standby}" "${changed}")"
  printf '%s\n' "${verdict}"
  case "${verdict}" in
    working) return "${EXIT_WORKING}" ;;
    standby) return "${EXIT_STANDBY}" ;;
    stuck) return "${EXIT_STUCK}" ;;
  esac
}

# Run main only when executed, not when sourced - so the test can source this file and drive
# classify_turn directly without running the CLI. The same seam barn.sh/timmy use.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
