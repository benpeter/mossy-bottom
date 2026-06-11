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
# Stalled-worker alert (Issue #29 - the worker-side analog of #20): each beat ALSO runs
# stuck-check on the WORKER (shirley) pane. timmy's stalled state (exit 40, #25) maps to stuck
# (#28), so a frozen worker classifies STUCK. When the worker is stuck AND shaun is PARKED on a
# STANDBY, we ALERT shaun (a wake to HIS pane: "your worker stalled - check shirley") so HIS
# judgment drives recovery: re-handing the current slice needs slice context, which is shaun's,
# not the heartbeat's. We NEVER type into shirley. The two shaun-aware branches share ONE
# classification of shaun per beat and partition it by verdict - #20 owns STUCK (exit 20), #29
# owns STANDBY (exit 10) - so they are DISJOINT and can never double-wake: a busy/working shaun
# (verdict 0) is never interrupted, and a genuinely stuck shaun is recovered by #20, not alerted.
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
#   MOSSY_HEARTBEAT_WORKER_TRIGGER override the worker-stalled alert text sent to shaun (#29)
#   MOSSY_SHAUN_FP               shaun's cross-beat fingerprint file (default: STATE_DIR/.shaun-fp)
#   MOSSY_WORKER_FP              shirley's cross-beat fingerprint file (default: STATE_DIR/.shirley-fp)
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

# Stalled-worker alert (#29). shirley's fingerprint persists BETWEEN beats, exactly like
# shaun's, so the worker 'changed' signal is cross-beat too.
WORKER_FP="${MOSSY_WORKER_FP:-${STATE_DIR}/.shirley-fp}"

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

# A DISTINCT worker-stalled ALERT for shaun (#29). Tagged "[heartbeat] worker-alert" so it is
# legible in logs and unmistakable from both the bitzer poll and shaun's own stuck-recovery. It
# only ALERTS shaun that his worker looks wedged; recovery (Esc + re-hand the current slice) is
# his judgment, needing slice context the heartbeat does not carry - and it NEVER types into
# shirley. Sent to shaun's pane only when shaun is parked on a STANDBY (disjoint from #20).
readonly DEFAULT_WORKER_TRIGGER='[heartbeat] worker-alert: shirley looks stalled (frozen spinner, no progress across two beats). Check her pane - if wedged, Esc to interrupt and re-hand the current slice from MISSION.md. Recovery is yours; this is only an alert.'
WORKER_TRIGGER="${MOSSY_HEARTBEAT_WORKER_TRIGGER:-${DEFAULT_WORKER_TRIGGER}}"

die() { printf 'heartbeat: %s\n' "$1" >&2; exit 64; }
log() { printf 'heartbeat %s | %s\n' "$(date '+%H:%M:%S')" "$1"; }

usage() {
  cat <<'EOF'
Usage: heartbeat.sh [--panes <file>] [--interval <secs>]   loop forever (default)
       heartbeat.sh --once [--panes <file>]                a single beat, then exit
       heartbeat.sh -h | --help

Each beat does three INDEPENDENT things from .barn-panes:
  - bitzer: classify with timmy and send the "run your sustaining poll" trigger ONLY if idle
    (skip if busy/waiting/asking - no mid-turn stacking). The poll body lives in bitzer.md.
  - shaun: run stuck-check.sh across beats (a persistent fingerprint), and on a STUCK verdict
    (idle, stable across two ticks, no STANDBY) clear his input line and send a stuck-recovery
    wake. working/standby do nothing. Skipped quietly if there is no shaun pane yet.
  - shirley (#29): run stuck-check.sh on the worker across beats, and when it is STUCK (a frozen
    spinner stable across two ticks) AND shaun is parked on a STANDBY, ALERT shaun (a wake to HIS
    pane) that his worker stalled - never typing into shirley. Disjoint from the shaun branch
    (that owns a STUCK shaun, this owns a STANDBY shaun), so the two never double-wake.
No timed expiry.

Env: MOSSY_STATE_DIR (.barn-panes dir), MOSSY_REPO_DIR (timmy location),
     MOSSY_HEARTBEAT_SECS (cadence, default 300), MOSSY_HEARTBEAT_TRIGGER (poll text),
     MOSSY_HEARTBEAT_STUCK_TRIGGER (stuck-recovery text), MOSSY_HEARTBEAT_WORKER_TRIGGER
     (worker-alert text), MOSSY_SHAUN_FP / MOSSY_WORKER_FP (fingerprint files).
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

# shirley_pane <panes_file> - print the WORKER's pane id (#29); fail if absent. Mirrors
# shaun_pane and is re-read each beat so a shirley relaunch is followed.
shirley_pane() {
  [ -f "$1" ] || return 1
  awk -F= '$1=="shirley"{print $2; ok=1} END{exit !ok}' "$1"
}

# send_trigger <pane> - literal text, a short beat, then a SEPARATE Enter. This is the
# established tmux send mechanics (docs/smoke-test.md): -l sends verbatim, and the Enter
# is its own call so the text lands before it is submitted.
send_trigger() {
  tmux send-keys -l -t "$1" -- "$TRIGGER"
  sleep 0.5
  tmux send-keys -t "$1" Enter
}

# send_wake <pane> <trigger> - mirror the proven-safe MANUAL recovery: a plain wake (trigger
# text + Enter). A live stuck turn (observed 2026-06-11) emits the malformed tool call as OUTPUT
# and ENDS the turn, leaving the input line EMPTY - so no interrupt is needed, and bitzer
# recovered it with exactly this plain wake. We keep only a leading C-u: a harmless readline
# line-clear, cheap insurance should a future variant leave a partial input line. We deliberately
# do NOT send C-c: its interrupt/exit semantics against a real Claude TUI are unverified and could
# be unsafe. Both the #20 stuck-recovery and the #29 worker-alert wake SHAUN's pane through this
# one mechanism (different trigger text); neither ever sends keys to shirley.
send_wake() {
  local pane="$1" trigger="$2"
  tmux send-keys -t "$pane" C-u
  tmux send-keys -l -t "$pane" -- "$trigger"
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

# shaun_verdict - classify shaun ONCE per beat and echo "<id> <rc>" (rc is stuck-check's exit
# code: 0 working, 10 standby, 20 stuck). Echoes nothing if there is no shaun pane / no
# stuck-check (the chain may not have shaun yet). This single classification is SHARED by both
# shaun-aware branches (#20 stuck-recovery and #29 worker-alert) so they read one verdict and
# can never double-wake. Never dies: stuck-check fails toward working, never stuck.
shaun_verdict() {
  local id
  [ -x "$STUCK_CHECK" ] || return 0
  id="$(shaun_pane "$panes_file")" || return 0
  MOSSY_TIMMY="$TIMMY" "$STUCK_CHECK" --pane "$id" --fingerprint-file "$SHAUN_FP" >/dev/null 2>&1
  printf '%s %s' "$id" "$?"
}

# beat_shaun <id> <rc> - the #20 stuck-recovery, INDEPENDENT of beat_bitzer (a frozen shaun must
# be woken whether or not bitzer is busy this beat). On a STUCK verdict (exit 20) send the
# recovery wake; working/standby/empty -> do nothing.
beat_shaun() {
  local id="$1" rc="$2"
  [ -n "$id" ] || return 0
  if [ "$rc" = "20" ]; then
    send_wake "$id" "$STUCK_TRIGGER"
    log "shaun STUCK (${id}) -> stuck-recovery wake sent"
  fi
}

# beat_worker <shaun_id> <shaun_rc> - the #29 worker-alert. Classify the WORKER (shirley) across
# beats; when it is STUCK (exit 20: a frozen spinner stable across two ticks, #28) AND shaun is
# parked on a STANDBY (shaun_rc=10), ALERT shaun on HIS pane so his judgment drives recovery -
# NEVER typing into shirley. The shaun_rc=10 gate makes this DISJOINT from beat_shaun (which owns
# shaun_rc=20), so the two never double-wake, and a busy/working shaun (rc=0) is never
# interrupted. Skipped QUIETLY when there is no shirley pane, no shaun to alert, or no
# stuck-check. Never dies: stuck-check fails toward working (never stuck).
beat_worker() {
  local shaun_id="$1" shaun_rc="$2" wid rc
  [ -n "$shaun_id" ] || return 0
  [ -x "$STUCK_CHECK" ] || return 0
  wid="$(shirley_pane "$panes_file")" || return 0
  MOSSY_TIMMY="$TIMMY" "$STUCK_CHECK" --pane "$wid" --fingerprint-file "$WORKER_FP" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 20 ] && [ "$shaun_rc" = "10" ]; then
    send_wake "$shaun_id" "$WORKER_TRIGGER"
    log "shirley STUCK (${wid}) + shaun parked (${shaun_id}) -> worker-alert wake sent to shaun"
  fi
}

# beat - one heartbeat: the bitzer poll nudge, then the two shaun-aware branches. Shaun is
# classified ONCE (shaun_verdict) and that result is shared by beat_shaun (#20) and beat_worker
# (#29), partitioned by verdict so they are disjoint and never double-wake. Each branch is
# self-contained and resilient, so one bad branch never stops the others or the loop.
beat() {
  beat_bitzer
  local sv shaun_id shaun_rc
  sv="$(shaun_verdict)"
  read -r shaun_id shaun_rc <<<"$sv"
  beat_shaun "$shaun_id" "$shaun_rc"
  beat_worker "$shaun_id" "$shaun_rc"
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
