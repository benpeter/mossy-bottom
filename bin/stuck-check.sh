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
#   stuck    state=stalled AND changed=0 (a frozen-spinner WEDGED turn, timmy exit 40 #25),
#            OR state=idle AND changed=0 AND has_standby=0 - both are dead, frozen turns the
#            heartbeat must recover. stalled maps to stuck DIRECTLY (a frozen spinner cannot
#            be a legit STANDBY pause), closing the #25-detection -> #20-recovery loop (#28).
#
# The function TRUSTS 'changed' as given. The await-vs-stuck distinction (a legitimately
# backgrounded await advances its pane within a heartbeat interval, so changed=1) is carried
# by HOW 'changed' is sampled - that sampling is a LATER slice, not this one.
#
# CLI: stuck-check.sh --state <idle|busy|waiting|question|stalled> --has-standby <0|1> --changed <0|1>
# prints the verdict and exits 0 (working) / 10 (standby) / 20 (stuck); 64 on a usage error.
#
# tva
set -uo pipefail

readonly EXIT_WORKING=0
readonly EXIT_STANDBY=10
readonly EXIT_STUCK=20
readonly EXIT_USAGE=64

# --pane (gather) mode config. timmy is the control-plane classifier (timmy/bin/timmy); its
# path is overridable for relocation/testing. STANDBY_PATTERN matches the line shaun ends a
# turn with (`STANDBY (context) - ...` or `STANDBY - ...`), allowing the leading `⏺` turn
# glyph. The fingerprint file persists the prior capture fingerprint BETWEEN calls - that
# CROSS-CALL stability (not timmy's intra-sample ~2s diff) is the 'stable across heartbeat
# ticks' signal #20 needs; the short intra-sample window cannot by itself mean stuck.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMMY="${MOSSY_TIMMY:-${SCRIPT_DIR}/../timmy/bin/timmy}"
STANDBY_PATTERN="${MOSSY_STANDBY_PATTERN:-^[[:space:]]*(⏺[[:space:]]*)?STANDBY([[:space:](]|$)}"

die() { printf 'stuck-check: %s\n' "$1" >&2; exit "${EXIT_USAGE}"; }

usage() {
  cat <<'EOF'
Usage:
  stuck-check.sh --state <idle|busy|waiting|question|stalled> --has-standby <0|1> --changed <0|1>
  stuck-check.sh --pane <id> --fingerprint-file <path>

Decide whether a pane is working, legitimately paused (standby), or stuck on a dead turn.

Explicit-inputs mode (the pure core):
  --state <s>        the pane's classified state (idle|busy|waiting|question|stalled)
  --has-standby <b>  1 if the pane shows a STANDBY marker, else 0
  --changed <b>      1 if the pane advanced (see --pane for how this is sampled), else 0

Live-pane mode (gathers the three inputs from a REAL pane):
  --pane <id>              tmux pane/target to inspect
  --fingerprint-file <p>   per-pane file holding the prior capture fingerprint (or env
                           MOSSY_STUCK_FP). The change signal is the fingerprint compared
                           ACROSS calls; the first call (no prior) is treated as changed=1.
    state       <- timmy (timmy/bin/timmy; override with MOSSY_TIMMY); exit 40 -> stalled (#25)
    has_standby <- a STANDBY marker line in the capture (override MOSSY_STANDBY_PATTERN)
    changed     <- this capture's fingerprint vs the prior call's
  A pane that cannot be read (timmy can't classify, capture fails) -> working, never stuck.

Verdict (printed) and exit code:
  working  0   busy|waiting|question, OR changed=1 (alive / advancing - wins even over stalled)
  standby 10   idle AND changed=0 AND has_standby=1 (legit paused turn)
  stuck   20   stalled with changed=0 (frozen-spinner wedged turn #25), OR idle AND changed=0
               AND has_standby=0 - both are dead, frozen turns the heartbeat recovers
  usage error 64
EOF
}

# classify_turn <state> <has_standby> <changed> - PURE: echo the verdict word for the given
# inputs, total over the documented domain (state in {idle,busy,waiting,question,stalled}; the
# two flags in {0,1}). No side effects, no I/O beyond the echo - this is the seam the test drives.
classify_turn() {
  local state="$1" has_standby="$2" changed="$3"
  # Safe direction wins first: a pane that MOVED this interval is alive / advancing -> working,
  # never stuck. This holds even for a momentarily 'stalled' read, which then gets another
  # heartbeat cycle (genuine work must never be recovered out from under itself).
  if [ "${changed}" = "1" ]; then
    printf 'working\n'
    return 0
  fi
  # A frozen-spinner 'stalled' turn (timmy exit 40, #25) is WEDGED -> stuck. It carries a frozen
  # spinner, so it cannot be a legit idle STANDBY pause; map it DIRECTLY, without consulting
  # has_standby (#28 - the new state #25 added, now wired into #20 recovery).
  if [ "${state}" = "stalled" ]; then
    printf 'stuck\n'
    return 0
  fi
  # Any OTHER non-idle state (busy|waiting|question) is genuinely alive -> working.
  if [ "${state}" != "idle" ]; then
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

# verdict_code <verdict> - the exit code for a verdict word (shared by both modes).
verdict_code() {
  case "$1" in
    working) return "${EXIT_WORKING}" ;;
    standby) return "${EXIT_STANDBY}" ;;
    stuck) return "${EXIT_STUCK}" ;;
    *) return "${EXIT_USAGE}" ;;
  esac
}

# fingerprint - read stdin, echo a stable content fingerprint (prefer sha, fall back to the
# always-present cksum). Used only to tell whether a capture CHANGED between calls.
fingerprint() {
  if command -v shasum >/dev/null 2>&1; then shasum | awk '{print $1}'
  elif command -v sha1sum >/dev/null 2>&1; then sha1sum | awk '{print $1}'
  else cksum | awk '{print $1 "-" $2}'
  fi
}

# pane_state <pane> - map timmy's exit code to a state word; return 1 if timmy could not
# classify (gone pane, usage error) so the caller can treat that as alive, never stuck.
# Exit 40 (stalled, #25) is a recognised state here (#28): a frozen-spinner WEDGED turn, which
# classify_turn routes to stuck - NOT the return-1 'cannot read -> working' path.
pane_state() {
  "${TIMMY}" --pane "$1" >/dev/null 2>&1
  case "$?" in
    0) printf 'idle' ;;
    10) printf 'busy' ;;
    20) printf 'waiting' ;;
    30) printf 'question' ;;
    40) printf 'stalled' ;;
    *) return 1 ;;
  esac
}

# run_pane <pane> <fpfile> - gather the three inputs from a REAL pane and classify:
#   state       <- timmy (pane_state)
#   has_standby <- a STANDBY marker line in the capture
#   changed     <- this capture's fingerprint vs the one persisted from the PRIOR call;
#                  no prior (first call) -> changed=1 (unknown means assume alive).
# Any read failure (timmy can't classify, capture fails) -> working: a pane we cannot read
# is never provably stuck. Prints the verdict and returns its exit code.
run_pane() {
  local pane="$1" fpfile="$2" state cap has_standby changed cur prior verdict
  if ! state="$(pane_state "${pane}")"; then
    printf 'working\n'
    return "${EXIT_WORKING}"
  fi
  if ! cap="$(tmux capture-pane -p -t "${pane}" 2>/dev/null)"; then
    printf 'working\n'
    return "${EXIT_WORKING}"
  fi
  if printf '%s\n' "${cap}" | LC_ALL=C grep -qE "${STANDBY_PATTERN}"; then has_standby=1; else has_standby=0; fi
  cur="$(printf '%s' "${cap}" | fingerprint)"
  prior="$(cat "${fpfile}" 2>/dev/null || true)"
  if [ -n "${prior}" ] && [ "${cur}" = "${prior}" ]; then changed=0; else changed=1; fi
  mkdir -p "$(dirname "${fpfile}")" 2>/dev/null || true
  printf '%s' "${cur}" >"${fpfile}"
  verdict="$(classify_turn "${state}" "${has_standby}" "${changed}")"
  printf '%s\n' "${verdict}"
  verdict_code "${verdict}"
}

main() {
  local state="" has_standby="" changed="" pane="" fpfile="${MOSSY_STUCK_FP:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --pane) shift; [ $# -gt 0 ] || die "--pane needs a value"; pane="$1" ;;
      --fingerprint-file) shift; [ $# -gt 0 ] || die "--fingerprint-file needs a value"; fpfile="$1" ;;
      --state) shift; [ $# -gt 0 ] || die "--state needs a value"; state="$1" ;;
      --has-standby) shift; [ $# -gt 0 ] || die "--has-standby needs a value"; has_standby="$1" ;;
      --changed) shift; [ $# -gt 0 ] || die "--changed needs a value"; changed="$1" ;;
      -h | --help) usage; return 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done

  # Live-pane mode: gather the three inputs from a real pane, then classify.
  if [ -n "${pane}" ]; then
    [ -z "${state}${has_standby}${changed}" ] || die "--pane cannot be combined with --state/--has-standby/--changed"
    [ -n "${fpfile}" ] || die "--pane needs --fingerprint-file <path> (or MOSSY_STUCK_FP)"
    command -v tmux >/dev/null 2>&1 || die "tmux not found (required for --pane)"
    run_pane "${pane}" "${fpfile}"
    return $?
  fi

  # Explicit-inputs mode (the pure core).
  [ -n "${state}" ] || die "--state is required (idle|busy|waiting|question)"
  [ -n "${has_standby}" ] || die "--has-standby is required (0|1)"
  [ -n "${changed}" ] || die "--changed is required (0|1)"
  case "${state}" in idle | busy | waiting | question | stalled) ;; *) die "invalid --state '${state}' (idle|busy|waiting|question|stalled)" ;; esac
  case "${has_standby}" in 0 | 1) ;; *) die "invalid --has-standby '${has_standby}' (0|1)" ;; esac
  case "${changed}" in 0 | 1) ;; *) die "invalid --changed '${changed}' (0|1)" ;; esac

  local verdict
  verdict="$(classify_turn "${state}" "${has_standby}" "${changed}")"
  printf '%s\n' "${verdict}"
  verdict_code "${verdict}"
}

# Run main only when executed, not when sourced - so the test can source this file and drive
# classify_turn directly without running the CLI. The same seam barn.sh/timmy use.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
