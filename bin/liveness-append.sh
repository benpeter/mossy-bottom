#!/usr/bin/env bash
#
# liveness-append.sh - the append hook. Two things get written here, and keeping them apart is
# the point, so read the distinction before wiring anything new into it.
#
#   --role <r> --state <working|standby> [--note <text>]
#       The AGENT recording its OWN state, into <state-dir>/liveness/<role>.state as
#       "<epoch> <role> <state> <session-id> <note>". Append-only, last line wins. This is where
#       a STANDBY survives: the pane is a 54-line alternate screen with no scrollback, so a
#       marker followed by a report is gone, and shaun's transcripts hold 220 markers his pane
#       showed none of. It also registers the agent's session id, which makes locating its
#       transcript exact instead of a sweep.
#
#       Written at an EVENT, never on a cadence. An agent writes only when it makes a tool call,
#       and legitimate turns on 2026-07-30 ran 40, 30, 15 and 12 minutes, so any mandated
#       interval would be a threshold no agent could honour - which is the class of false
#       positive this work exists to remove.
#
#   --tool <name>
#       A HARNESS TOOL recording that its caller's session was alive, into
#       <state-dir>/liveness/sessions as "<epoch> <session-id> <tool>". Keyed by SESSION and not
#       by role, because no tool can know its caller's role: send-verified run by shaun targets
#       shirley's pane, so the caller's session and the subject's pane never coincide.
#
#   --tick <label> [--note <text>]
#       One tick line into <state-dir>/TICKS.md as "HH:MM | <label> | <text>", with the HH:MM
#       from `date`. Without --note the text comes from stdin, one tick line per input line, so a
#       batch is one call. This exists because the stamp cannot be left to the agent: on
#       2026-07-31 bitzer's tick stamps crossed real time at 06:37 and read 12:30 at a real
#       09:20, +190 minutes, and he named the cause himself - "I have never once run date to
#       stamp a tick. I composed them from my own sense of elapsed time, adding a plausible
#       interval per batch." shaun's drifted in both directions with one stamp going backwards,
#       and shaun's prompt had carried the instruction to read `date` all along.
#
#       A tick writes NOTHING to liveness/, and that is load-bearing rather than tidy. shaun
#       ticks about every 150s and liveness-read's activity_age reads liveness/<role>.state, so a
#       per-tick write there would keep that file permanently fresh and "nothing appended for
#       600s" could never be observed again. A tick is a narrative record, not a liveness one.
#
# WHY THE SESSION LOG IS A SEPARATE FILE, and why that is not tidiness. bin/liveness-read.sh
# computes liveness from the freshest of the transcript and the agent's own state line. If a tool
# invocation refreshed that timestamp, then timmy - which the heartbeat calls every single beat -
# would keep the file permanently fresh, and "nothing appended for 600s" would become impossible
# to observe. "The file is fresh" would mean "I just looked". Acceptance case 4 forbids precisely
# that: do not fix the false positives by making the detector blind. So the session log is never
# read for liveness, and activity_age does not look at it.
#
# The second half of that guard is free. CLAUDE_CODE_SESSION_ID is set only inside an agent's own
# process, and the heartbeat is a plain bash loop, so a heartbeat-driven timmy call has no session
# id and writes nothing at all. The observer cannot refresh what it is observing.
#
# HARD RULE: this hook must never fail its caller. A tool that could not record liveness still
# has its own job to do, so every failure path here exits 0 and writes nothing. The only nonzero
# exit is a usage error, which is a wiring mistake rather than a runtime condition.
#
# tva
set -uo pipefail

readonly EXIT_OK=0
readonly EXIT_USAGE=64

STATE_DIR="${MOSSY_STATE_DIR:-}"
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"

die() { printf 'liveness-append: %s\n' "$1" >&2; exit "${EXIT_USAGE}"; }

usage() {
  cat <<'EOF'
Usage:
  liveness-append.sh --role <shaun|bitzer|shirley> --state <working|standby> [--note <text>]
  liveness-append.sh --tool <name>
  liveness-append.sh --tick <label> [--note <text>]

Record liveness and state into the run's state dir. Called as a side effect by the harness
tools, and by an agent itself when it parks or ticks.

  --role/--state   the agent recording its OWN state, into liveness/<role>.state as
                   "<epoch> <role> <state> <session-id> <note>". Append-only, last line wins.
                   Also registers CLAUDE_CODE_SESSION_ID so the agent's transcript can be
                   located exactly rather than swept for.
  --tool <name>    a harness tool recording that its CALLER's session was alive, into
                   liveness/sessions as "<epoch> <session-id> <tool>".
  --tick <label>   one line into TICKS.md as "HH:MM | <label> | <text>", the HH:MM from date so
                   an agent never authors it. Without --note the text comes from stdin, one
                   tick line per input line. The label is free-form. Writes nothing to
                   liveness/, so a tick every 150s cannot blind the staleness check.

The session log is never read for liveness: a tool refreshing the timestamp the stuck check
reads would make "nothing appended for 600s" unobservable. With CLAUDE_CODE_SESSION_ID unset
(the heartbeat) nothing is written at all.

Environment:
  MOSSY_STATE_DIR          the run's state dir. Unset -> silent no-op.
  CLAUDE_CODE_SESSION_ID   set by Claude Code inside an agent's process. Unset -> no session
                           line is written.

Exits 0 even when it cannot write: this hook must never fail the tool that called it. 64 is a
usage error only.
EOF
}

# liveness_dir - echo the directory the files live in, or return 1 when unconfigured.
liveness_dir() {
  [ -n "${STATE_DIR}" ] || return 1
  printf '%s' "${STATE_DIR}/liveness"
}

# append_line <file> <text> - append one line, swallowing every failure. Deliberately quiet: a
# tool must not learn about a full disk from us.
append_line() {
  local f="$1" text="$2" d
  d="$(dirname "${f}")"
  mkdir -p "${d}" 2>/dev/null || return 0
  printf '%s\n' "${text}" >>"${f}" 2>/dev/null || return 0
}

# append_state <role> <state> <note> - the agent's own state line.
append_state() {
  local role="$1" state="$2" note="$3" d sid
  d="$(liveness_dir)" || return 0
  # A missing session id is recorded as '-', which resolve_session's uuid shape rejects, so an
  # unregistered agent is never mistaken for one registered to a bogus transcript.
  sid="${SESSION_ID:--}"
  append_line "${d}/${role}.state" "$(date +%s) ${role} ${state} ${sid} ${note}"
}

# append_tool <name> - the session liveness log. No session id means no line, which is what
# keeps a heartbeat-driven observer from refreshing the timestamp it is about to read.
append_tool() {
  local tool="$1" d
  [ -n "${SESSION_ID}" ] || return 0
  d="$(liveness_dir)" || return 0
  append_line "${d}/sessions" "$(date +%s) ${SESSION_ID} ${tool}"
}

# append_tick <label> <text> - one tick line, stamped from date. A newline in the text is
# collapsed to a space: a tick is one line by contract, and splitting one would leave a line with
# no stamp, which is the file's only invariant. Collapsed rather than rejected, because this hook
# must never fail its caller.
append_tick() {
  local label="$1" text="$2"
  [ -n "${STATE_DIR}" ] || return 0
  text="$(printf '%s' "${text}" | tr '\n' ' ')"
  append_line "${STATE_DIR}/TICKS.md" "$(date +%H:%M) | ${label} | ${text}"
}

# append_ticks_stdin <label> - one tick line per line of stdin, each with its own stamp. This is
# the batch form: bitzer writes five to seven lines per tick and already does it in one heredoc.
append_ticks_stdin() {
  local label="$1" line
  [ -n "${STATE_DIR}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    [ -n "${line}" ] || continue
    append_tick "${label}" "${line}"
  done
}

main() {
  local role="" state="" note="" tool="" tick="" have_note=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) shift; [ $# -gt 0 ] || die "--role needs a value"; role="$1" ;;
      --state) shift; [ $# -gt 0 ] || die "--state needs a value"; state="$1" ;;
      --note) shift; [ $# -gt 0 ] || die "--note needs a value"; note="$1"; have_note=1 ;;
      --tool) shift; [ $# -gt 0 ] || die "--tool needs a value"; tool="$1" ;;
      --tick) shift; [ $# -gt 0 ] || die "--tick needs a label"; tick="$1" ;;
      -h | --help) usage; return "${EXIT_OK}" ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done

  if [ -n "${tick}" ]; then
    if [ "${have_note}" -eq 1 ]; then append_tick "${tick}" "${note}"; else append_ticks_stdin "${tick}"; fi
    return "${EXIT_OK}"
  fi

  if [ -n "${tool}" ]; then
    append_tool "${tool}"
    return "${EXIT_OK}"
  fi

  [ -n "${role}" ] || die "need --role <name> --state <working|standby>, or --tool <name>"
  [ -n "${state}" ] || die "--role needs --state <working|standby>"
  # Only the two words the reader understands. An unrecognised state would leave the reader
  # guessing, which is the drift this whole change is removing.
  case "${state}" in working | standby) ;; *) die "invalid --state '${state}' (working|standby)" ;; esac
  append_state "${role}" "${state}" "${note}"
  return "${EXIT_OK}"
}

if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  main "$@"
  exit $?
fi
