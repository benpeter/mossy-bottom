#!/usr/bin/env bash
#
# heartbeat.sh - the autonomous sustain trigger for bitzer (Issue #13).
#
# bitzer is a conversational agent: it runs its sustaining poll (check shaun, wake an
# unforced STANDBY, keep the queue non-empty, commit/push when ahead, rotate) ONLY when
# its pane receives input. Nothing autonomously delivers that input, so an idle run can
# stall for hours until a human pokes (it did: ~4h on 2026-06-10). This is the durable
# TRIGGER - a vanilla loop that, on a cadence, nudges bitzer's pane to run the poll, with
# no human and no silent expiry.
#
# Single source of truth: the poll PROCEDURE lives in prompts/bitzer.md. This tool only
# TRIGGERS it with a terse message; it never carries a copy of the poll body, so the two
# can never drift (the MISSION lesson).
#
# timmy-gated: each beat classifies bitzer's pane and nudges ONLY when it is idle. If
# bitzer is busy, waiting, or asking, the beat is SKIPPED - never stack input mid-turn.
#
# Stuck-shaun recovery (Issue #20): each beat ALSO runs an INDEPENDENT check on shaun's pane
# via bin/stuck-check.sh - independent because a frozen shaun must be woken whether or not
# bitzer is busy this beat. A malformed tool call can freeze shaun mid-turn with no spinner
# and no STANDBY: he reads idle and never advances, so nothing nudges him and the run stalls.
# stuck-check compares a fingerprint ACROSS beats (a persistent file under STATE_DIR), so
# 'stuck' means idle AND stable across two heartbeat ticks AND no STANDBY. On that verdict we
# clear shaun's input line (in case a malformed fragment is sitting in it) and send a distinct
# stuck-recovery wake; working/standby/unreadable do nothing. This keeps the decision OUT of
# bitzer's in-the-moment judgment - it is mechanical, not an eyeball call.
#
# Lifecycle: this loop is meant to run inside the tmux session as a background window
# (the wiring is barn.sh's job - a later slice), so it lives and dies with the chain,
# which is the correct lifecycle: a dead session has no bitzer to nudge. It has no timed
# expiry - it runs until the loop, or the session, is killed.
#
# Standalone control-plane tool, invoked by absolute path like timmy, rotate.sh, and
# watchdog.sh - not a barn.sh subcommand.
#
# Usage:
#   heartbeat.sh [--panes <file>] [--interval <secs>]   loop forever (default)
#   heartbeat.sh --once [--panes <file>]                a single beat, then exit (proof)
#   heartbeat.sh -h | --help
#
# Config via env:
#   MOSSY_STATE_DIR              dir holding .barn-panes (default: repo root / dogfood)
#   MOSSY_REPO_DIR               harness repo root, where timmy lives (default: resolved)
#   MOSSY_HEARTBEAT_SECS         cadence in seconds (default: 300)
#   MOSSY_HEARTBEAT_TRIGGER      override the bitzer poll trigger (default: aligned to bitzer.md)
#   MOSSY_HEARTBEAT_STUCK_TRIGGER  override the shaun stuck-recovery wake text
#   MOSSY_SHAUN_FP               shaun's cross-beat fingerprint file (default: STATE_DIR/.shaun-fp)
#
# tva
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INTERVAL="${MOSSY_HEARTBEAT_SECS:-300}"
STATE_DIR="${MOSSY_STATE_DIR:-${REPO_ROOT}}"
TIMMY="${MOSSY_REPO_DIR:-${REPO_ROOT}}/timmy/bin/timmy"

# Stuck-shaun recovery (#20). stuck-check.sh is the sibling control-plane tool; the shaun
# fingerprint persists BETWEEN beats (under STATE_DIR by default) so 'changed' means moved
# across two heartbeat ticks, not within timmy's ~2s intra-sample window.
STUCK_CHECK="${SCRIPT_DIR}/stuck-check.sh"
SHAUN_FP="${MOSSY_SHAUN_FP:-${STATE_DIR}/.shaun-fp}"

# The terse trigger. The poll body is bitzer.md's, not ours - we only say "go poll", so
# there is one source of truth and nothing to drift. The "[heartbeat]" tag marks it as
# the autonomous nudge, distinct from a Farmer message. Override via env for tests.
readonly DEFAULT_TRIGGER='[heartbeat] Run your sustaining poll now - check shaun and the run health and act per your role (wake shaun if he is on an unforced STANDBY; keep the open queue non-empty; commit and push when ahead; rotate on cadence).'
TRIGGER="${MOSSY_HEARTBEAT_TRIGGER:-${DEFAULT_TRIGGER}}"

# A DISTINCT stuck-recovery wake for a frozen shaun (#20). Tagged "[heartbeat] stuck-recovery"
# so it is legible in logs and unmistakable from the bitzer poll trigger. It only re-anchors
# shaun on his files and tells him to continue - the procedure is shaun.md's, not ours.
readonly DEFAULT_STUCK_TRIGGER='[heartbeat] stuck-recovery: your turn looks frozen (idle, no progress, no STANDBY). Re-anchor on your MISSION.md and GUARDRAILS.md and resume your tick loop - re-read shirley pane and continue driving.'
STUCK_TRIGGER="${MOSSY_HEARTBEAT_STUCK_TRIGGER:-${DEFAULT_STUCK_TRIGGER}}"

die() { printf 'heartbeat: %s\n' "$1" >&2; exit 64; }
log() { printf 'heartbeat %s | %s\n' "$(date '+%H:%M:%S')" "$1"; }

usage() {
  cat <<'EOF'
Usage: heartbeat.sh [--panes <file>] [--interval <secs>]   loop forever (default)
       heartbeat.sh --once [--panes <file>]                a single beat, then exit
       heartbeat.sh -h | --help

Each beat does two INDEPENDENT things from .barn-panes:
  - bitzer: classify with timmy and send the "run your sustaining poll" trigger ONLY if idle
    (skip if busy/waiting/asking - no mid-turn stacking). The poll body lives in bitzer.md.
  - shaun: run stuck-check.sh across beats (a persistent fingerprint), and on a STUCK verdict
    (idle, stable across two ticks, no STANDBY) clear his input line and send a stuck-recovery
    wake. working/standby do nothing. Skipped quietly if there is no shaun pane yet.
No timed expiry.

Env: MOSSY_STATE_DIR (.barn-panes dir), MOSSY_REPO_DIR (timmy location),
     MOSSY_HEARTBEAT_SECS (cadence, default 300), MOSSY_HEARTBEAT_TRIGGER (poll text),
     MOSSY_HEARTBEAT_STUCK_TRIGGER (stuck-recovery text), MOSSY_SHAUN_FP (fingerprint file).
EOF
}

panes_file="${STATE_DIR}/.barn-panes"
once=0
while [ $# -gt 0 ]; do
  case "$1" in
    --once) once=1 ;;
    --panes) shift; [ $# -gt 0 ] || die "--panes needs a value"; panes_file="$1" ;;
    --interval) shift; [ $# -gt 0 ] || die "--interval needs a value"; INTERVAL="$1" ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

case "$INTERVAL" in
  '' | *[!0-9]*) die "--interval / MOSSY_HEARTBEAT_SECS needs an integer (seconds)" ;;
esac
[ "$INTERVAL" -ge 1 ] || die "cadence must be at least 1 second (got ${INTERVAL})"
[ -x "$TIMMY" ] || die "timmy not found or not executable at ${TIMMY} (set MOSSY_REPO_DIR)"

# bitzer_pane <panes_file> - print bitzer's pane id from the panes file; fail if absent.
# Re-read every beat (not cached) so a bitzer relaunch is followed: respawn-pane keeps
# the id, but reading the file each time is robust and cheap.
bitzer_pane() {
  [ -f "$1" ] || return 1
  awk -F= '$1=="bitzer"{print $2; ok=1} END{exit !ok}' "$1"
}

# shaun_pane <panes_file> - print shaun's pane id; fail if absent. Mirrors bitzer_pane and
# is re-read each beat so a shaun relaunch is followed.
shaun_pane() {
  [ -f "$1" ] || return 1
  awk -F= '$1=="shaun"{print $2; ok=1} END{exit !ok}' "$1"
}

# send_trigger <pane> - literal text, a short beat, then a SEPARATE Enter. This is the
# established tmux send mechanics (docs/smoke-test.md): -l sends verbatim, and the Enter
# is its own call so the text lands before it is submitted.
send_trigger() {
  tmux send-keys -l -t "$1" -- "$TRIGGER"
  sleep 0.5
  tmux send-keys -t "$1" Enter
}

# wake_shaun <pane> - a stuck-recovery wake that lands cleanly even if a malformed tool-call
# fragment is sitting in shaun's input line: CLEAR the line (C-u) and cancel any partial state
# (C-c) FIRST, then send the distinct stuck-recovery trigger (literal text, a beat, a separate
# Enter, per the smoke-test send mechanics). The trigger re-anchors shaun; he continues per
# shaun.md - we carry no copy of his procedure.
wake_shaun() {
  local pane="$1"
  tmux send-keys -t "$pane" C-u
  tmux send-keys -t "$pane" C-c
  sleep 0.3
  tmux send-keys -l -t "$pane" -- "$STUCK_TRIGGER"
  sleep 0.5
  tmux send-keys -t "$pane" Enter
}

# beat_bitzer - the poll nudge. Read bitzer's id, classify with timmy, nudge IFF idle
# (exit 0), otherwise skip. Never dies on a single bad beat - the loop must outlive transient
# trouble (a momentarily gone pane, a panes file not yet written).
beat_bitzer() {
  local id state rc
  id="$(bitzer_pane "$panes_file")" \
    || { log "no bitzer pane id in ${panes_file} - skip"; return 0; }
  state="$("$TIMMY" --pane "$id" 2>/dev/null)"
  rc=$?
  case "$rc" in
    0) send_trigger "$id"; log "bitzer idle (${id}) -> nudged" ;;
    10 | 20 | 30) log "bitzer ${state:-busy} (${id}, rc=${rc}) -> skip (no mid-turn stacking)" ;;
    *) log "timmy could not classify ${id} (rc=${rc}) -> skip (pane gone?)" ;;
  esac
}

# beat_shaun - the stuck-recovery check, INDEPENDENT of beat_bitzer (a frozen shaun must be
# woken whether or not bitzer is busy this beat). Read shaun's id (skip QUIETLY if absent -
# the chain may not have shaun yet), run stuck-check across beats via the persistent
# fingerprint, and on a STUCK verdict (exit 20) clear his line and send the recovery wake.
# working/standby/unreadable -> do nothing. Never dies: stuck-check itself fails toward
# working (never stuck), and a missing stuck-check just degrades to a bitzer-only beat.
beat_shaun() {
  local id rc
  [ -x "$STUCK_CHECK" ] || return 0
  id="$(shaun_pane "$panes_file")" || return 0
  MOSSY_TIMMY="$TIMMY" "$STUCK_CHECK" --pane "$id" --fingerprint-file "$SHAUN_FP" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 20 ]; then
    wake_shaun "$id"
    log "shaun STUCK (${id}) -> stuck-recovery wake sent"
  fi
}

# beat - one heartbeat: the bitzer poll nudge, then the INDEPENDENT shaun stuck-check. Each
# branch is self-contained and resilient, so one bad branch never stops the other or the loop.
beat() {
  beat_bitzer
  beat_shaun
}

if [ "$once" -eq 1 ]; then
  beat
  exit 0
fi

# Loop forever. Clean exit on a signal (the window is killed with the chain). Sleep
# FIRST so the first nudge is one cadence after launch - the chain gets time to boot
# before any beat, and a still-booting bitzer would be skipped as non-idle anyway.
trap 'exit 0' INT TERM
log "heartbeat up: nudging bitzer's poll every ${INTERVAL}s (panes ${panes_file})"
while :; do
  sleep "$INTERVAL"
  beat
done
