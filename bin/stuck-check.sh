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

# Ground-truth inputs (see classify_turn_live). All three are optional: without them this tool
# behaves exactly as it did, reading the screen. SESSION_ID is the agent's own Claude Code
# session id, which names its transcript; the agent's tools record it into STATE_FILE, and it
# has to be re-read rather than cached because /clear mints a new one (shirley acquired six
# transcript files in 3.5 hours on 2026-07-30).
LIVENESS_READ="${MOSSY_LIVENESS_READ:-${SCRIPT_DIR}/liveness-read.sh}"
STATE_FILE="${MOSSY_STATE_FILE:-}"
SESSION_ID="${MOSSY_SESSION_ID:-}"
# Deliberately NOT defaulted to $PWD. The heartbeat window inherits the harness repo as its cwd
# (bin/barn.sh:674 has no -c), so $PWD here is the wrong tree; left empty, liveness-read derives
# the agent's cwd from the state dir instead.
AGENT_CWD="${MOSSY_AGENT_CWD:-}"

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
    has_standby <- a STANDBY marker in the capture OR in --state-file's last line
    changed     <- this capture's fingerprint vs the prior call's
  A pane that cannot be read (timmy can't classify, capture fails) -> working, never stuck.

Ground truth (optional; without it this tool reads the screen exactly as it always did):
  --state-file <f>   the role's append-only state file (env MOSSY_STATE_FILE). Carries the
                     agent's state word and its current session id, and keeps a STANDBY that
                     has scrolled off the pane.
  --session <id>     the agent's Claude Code session id (env MOSSY_SESSION_ID). Read from
                     --state-file when not given, which is preferable: /clear mints a new id
                     and the file follows it.
  --agent-cwd <p>    the agent's working directory (env MOSSY_AGENT_CWD), needed to locate its
                     transcript. Left unset on purpose: liveness-read derives it from the state
                     dir, because the heartbeat window's own $PWD is the harness repo rather
                     than the tree the agents run in.
  When a session resolves, bin/liveness-read.sh decides and this tool maps its verdict:
  working -> working, parked -> standby, stuck -> stuck. Otherwise the screen decides.

PRECEDENCE. The transcript is authoritative for liveness and for whether a turn is still open.
The state file is authoritative for what the agent is doing and for a STANDBY the pane has
discarded. The pane is authoritative only for what renders THIS INSTANT: a spinner, a retry
ladder, and the context percent. Full reasoning in bin/liveness-read.sh's header.

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

# classify_turn_live <liveness> <state> <has_standby> <changed> - the LIVENESS LAYER over the
# pure core, and the place the precedence is written down: liveness WINS, and classify_turn is
# the fallback for when no transcript can be resolved.
#
# Why a layer rather than a rewrite of classify_turn. The three inputs classify_turn takes are
# all read off a 54-line alternate screen that keeps no scrollback, so has_standby and the
# capture fingerprint are both answers from a window that throws history away. Measured on
# 2026-07-30: 21 stuck-recovery wakes fired at shaun and every one landed on a turn that had
# ALREADY ENDED - not one on a hung tool call. Only 3 of the 21 were the scroll-off shape this
# STANDBY_PATTERN was tightened for; the other 18 were a completed turn parked 5.7 to 10.4
# minutes waiting on shirley, with no marker anywhere to find.
#
# The mapping into this tool's existing verdicts, which heartbeat.sh already partitions on:
#   working -> working (0). An open turn that appended recently, or a live pane.
#   parked  -> standby (10). The turn ENDED. That is what exit 10 already means to the
#              heartbeat: a shaun who can receive, which gates the worker wakes.
#   stuck   -> stuck (20). The turn is open, nothing was appended for the threshold, and the
#              pane renders neither a spinner nor a retry ladder.
#   empty   -> classify_turn, unchanged, byte-for-byte. No transcript resolved, so we are back
#              to the screen and should be honest that that is what we are reading.
#
# NOTE this widens exit 10. It used to mean "a STANDBY marker is visible on the pane"; it now
# means "the turn has ended", which is true far more often and is the point. The worker wakes
# gated on shaun_rc=10 therefore fire on a parked shaun whether or not he wrote a marker.
classify_turn_live() {
  local liveness="$1" state="$2" has_standby="$3" changed="$4"
  case "${liveness}" in
    working) printf 'working\n'; return 0 ;;
    parked) printf 'standby\n'; return 0 ;;
    stuck) printf 'stuck\n'; return 0 ;;
  esac
  classify_turn "${state}" "${has_standby}" "${changed}"
}

# standby_from_state <state-file> - echo 1 if the agent's own last state line says it parked.
#
# This is the marker that scrolled off. shaun's transcripts carry 220 STANDBY lines while his
# pane showed none of them once a report followed, because a median marker is 248 characters and
# 90 of them are trailed by another 464 to 1887 characters, which clears a 54-line viewport. A
# file keeps what the pane discards.
#
# Matched on the bare token, deliberately. Three separator forms occur in the wild over those
# 220 records: 'STANDBY (context) - ', 'STANDBY - ' and 'STANDBY — ' with an em dash, plus two
# parentheticals, (context) and (worker). Keying on any one of them misses the rest.
# The state word is field 3 of the last line, matched on the field rather than anywhere in the
# line: a working agent's note routinely mentions STANDBY (shaun writes about the marker while
# not being on one), and a substring match would read that as a park.
standby_from_state() {
  local sf="${1:-}" w
  if [ ! -s "${sf}" ]; then printf '0'; return 0; fi
  w="$(tail -n 1 "${sf}" 2>/dev/null | awk '{print tolower($3)}')"
  if [ "${w}" = "standby" ]; then printf '1'; else printf '0'; fi
}

# session_from_state <state-file> - echo the session id field 4 of the last line. The tools
# record it on every call, so the value follows a /clear on its own instead of going stale.
session_from_state() {
  [ -s "${1:-}" ] || return 0
  tail -n 1 "$1" 2>/dev/null | awk '$4 ~ /^[0-9a-f]{8}-/ {print $4}'
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
  local pane="$1" fpfile="$2" state cap has_standby changed cur prior verdict liveness=""
  if ! state="$(pane_state "${pane}")"; then
    printf 'working\n'
    return "${EXIT_WORKING}"
  fi
  if ! cap="$(tmux capture-pane -p -t "${pane}" 2>/dev/null)"; then
    printf 'working\n'
    return "${EXIT_WORKING}"
  fi
  # has_standby from EITHER source. The capture is kept because it is free once we hold it, but
  # the state file is the one that survives: a marker scrolls off a 54-line viewport and 90 of
  # shaun's 220 real markers are trailed by 464 to 1887 more characters.
  if printf '%s\n' "${cap}" | LC_ALL=C grep -qE "${STANDBY_PATTERN}"; then has_standby=1; else has_standby=0; fi
  if [ "${has_standby}" = "0" ] && [ -n "${STATE_FILE}" ]; then has_standby="$(standby_from_state "${STATE_FILE}")"; fi
  cur="$(printf '%s' "${cap}" | fingerprint)"
  prior="$(cat "${fpfile}" 2>/dev/null || true)"
  if [ -n "${prior}" ] && [ "${cur}" = "${prior}" ]; then changed=0; else changed=1; fi
  mkdir -p "$(dirname "${fpfile}")" 2>/dev/null || true
  printf '%s' "${cur}" >"${fpfile}"
  # Ground truth, when we can resolve it. Invoked by path like the heartbeat invokes us, so the
  # two tools stay independent. Any failure leaves liveness empty and classify_turn_live falls
  # back to the screen - never worse than what this replaced.
  #
  # We pass the pane and the state dir and let the reader derive the role from .barn-panes, so
  # NO CALLER HAS TO CHANGE. That is deliberate: heartbeat.sh is a long-running process and
  # editing it would need a chain relaunch, but it re-execs this script by path every beat.
  if [ -x "${LIVENESS_READ}" ]; then
    liveness="$("${LIVENESS_READ}" --pane "${pane}" \
      ${AGENT_CWD:+--cwd "${AGENT_CWD}"} \
      ${MOSSY_STATE_DIR:+--state-dir "${MOSSY_STATE_DIR}"} \
      ${SESSION_ID:+--session "${SESSION_ID}"} \
      ${STATE_FILE:+--state-file "${STATE_FILE}"} 2>/dev/null || true)"
  fi
  verdict="$(classify_turn_live "${liveness}" "${state}" "${has_standby}" "${changed}")"
  printf '%s\n' "${verdict}"
  verdict_code "${verdict}"
}

main() {
  local state="" has_standby="" changed="" pane="" fpfile="${MOSSY_STUCK_FP:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --pane) shift; [ $# -gt 0 ] || die "--pane needs a value"; pane="$1" ;;
      --fingerprint-file) shift; [ $# -gt 0 ] || die "--fingerprint-file needs a value"; fpfile="$1" ;;
      --state-file) shift; [ $# -gt 0 ] || die "--state-file needs a value"; STATE_FILE="$1" ;;
      --session) shift; [ $# -gt 0 ] || die "--session needs a value"; SESSION_ID="$1" ;;
      --agent-cwd) shift; [ $# -gt 0 ] || die "--agent-cwd needs a value"; AGENT_CWD="$1" ;;
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
    # A state file that carries a session id makes --session redundant; prefer the file, since
    # it follows a /clear and an explicitly passed id does not.
    if [ -z "${SESSION_ID}" ] && [ -n "${STATE_FILE}" ]; then SESSION_ID="$(session_from_state "${STATE_FILE}")"; fi
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
