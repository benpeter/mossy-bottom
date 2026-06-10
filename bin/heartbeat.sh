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
#   MOSSY_STATE_DIR          dir holding .barn-panes (default: repo root / dogfood)
#   MOSSY_REPO_DIR           harness repo root, where timmy lives (default: resolved)
#   MOSSY_HEARTBEAT_SECS     cadence in seconds (default: 300)
#   MOSSY_HEARTBEAT_TRIGGER  override the terse trigger text (default: aligned to bitzer.md)
#
# tva
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INTERVAL="${MOSSY_HEARTBEAT_SECS:-300}"
STATE_DIR="${MOSSY_STATE_DIR:-${REPO_ROOT}}"
TIMMY="${MOSSY_REPO_DIR:-${REPO_ROOT}}/timmy/bin/timmy"

# The terse trigger. The poll body is bitzer.md's, not ours - we only say "go poll", so
# there is one source of truth and nothing to drift. The "[heartbeat]" tag marks it as
# the autonomous nudge, distinct from a Farmer message. Override via env for tests.
readonly DEFAULT_TRIGGER='[heartbeat] Run your sustaining poll now - check shaun and the run health and act per your role (wake shaun if he is on an unforced STANDBY; keep the open queue non-empty; commit and push when ahead; rotate on cadence).'
TRIGGER="${MOSSY_HEARTBEAT_TRIGGER:-${DEFAULT_TRIGGER}}"

die() { printf 'heartbeat: %s\n' "$1" >&2; exit 64; }
log() { printf 'heartbeat %s | %s\n' "$(date '+%H:%M:%S')" "$1"; }

usage() {
  cat <<'EOF'
Usage: heartbeat.sh [--panes <file>] [--interval <secs>]   loop forever (default)
       heartbeat.sh --once [--panes <file>]                a single beat, then exit
       heartbeat.sh -h | --help

Reads bitzer's pane id from .barn-panes, then on each beat classifies that pane with
timmy and sends a terse "run your sustaining poll" trigger ONLY if the pane is idle;
if bitzer is busy/waiting/asking, the beat is skipped (no mid-turn stacking). The poll
procedure itself lives in prompts/bitzer.md - this only triggers it. No timed expiry.

Env: MOSSY_STATE_DIR (.barn-panes dir), MOSSY_REPO_DIR (timmy location),
     MOSSY_HEARTBEAT_SECS (cadence, default 300), MOSSY_HEARTBEAT_TRIGGER (trigger text).
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

# send_trigger <pane> - literal text, a short beat, then a SEPARATE Enter. This is the
# established tmux send mechanics (docs/smoke-test.md): -l sends verbatim, and the Enter
# is its own call so the text lands before it is submitted.
send_trigger() {
  tmux send-keys -l -t "$1" -- "$TRIGGER"
  sleep 0.5
  tmux send-keys -t "$1" Enter
}

# beat - one heartbeat. Read bitzer's id, classify with timmy, nudge IFF idle (exit 0),
# otherwise skip. Never dies on a single bad beat - the loop must outlive transient
# trouble (a momentarily gone pane, a panes file not yet written).
beat() {
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
