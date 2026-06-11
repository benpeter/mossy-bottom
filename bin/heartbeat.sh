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
# stuck-recovery wake - delivered VIA send-verified (#32) so the wake itself cannot silently
# buffer-unsent on the very path the recovery net relies on; working/standby/unreadable do
# nothing. This keeps the decision OUT of bitzer's in-the-moment judgment - mechanical, not an
# eyeball call.
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
# Worker-done event wake (Issue #36, MISSION #2 Economy - first slice): each beat ALSO detects when the
# WORKER has FINISHED a slice and is sitting idle awaiting the next hand, and wakes shaun on an EVENT
# instead of the old fixed-interval blind poll. The worker is classified ONCE per beat (worker_verdict)
# and partitioned by its raw timmy STATE so the two worker branches are disjoint: #29 owns 'stalled' (a
# frozen-spinner wedged turn, timmy exit 40), #36 owns 'done' (idle, timmy exit 0). stuck-check collapses
# BOTH into one 'stuck' verdict (idle-stable-no-standby AND stalled both map to exit 20, #28), so a single
# timmy re-read of the now-static pane splits the dead-stable verdict back into done-vs-stalled - that
# split is what keeps #36 from double-waking with #29. The done-wake requires the worker idle across TWO
# consecutive beats (stuck-check's exit 20 already demands changed=0, i.e. content stable across beats, so
# a transient one-beat idle never fires) AND shaun PARKED on a STANDBY; a BUSY worker does NOTHING (no
# wake - the economy win). The wake goes to SHAUN's pane (we never type into shirley); recovery/direction
# is shaun's. NOTE this lands only at the next launch - the running chain keeps its current wake model.
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
#   MOSSY_HEARTBEAT_WORKER_DONE_TRIGGER override the worker-done wake text sent to shaun (#36)
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

# send-verified.sh (#31, adopted by #32) - the verified deliverer for the RECOVERY wakes. A
# recovery wake IS the safety net: if it silently buffers-unsent (the 06:39 race), the stuck
# state just persists and the chain stays dead. send-verified types, then confirms via timmy
# that the pane went busy (the turn started), retrying ONCE before giving up - so a failed
# recovery delivery is caught and logged, not lost. Only the recovery wakes use it; the
# frequent bitzer sustain trigger stays a plain fire-and-forget send (a separate follow-up).
SEND_VERIFIED="${SCRIPT_DIR}/send-verified.sh"

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

# A DISTINCT worker-DONE wake for shaun (#36, MISSION #2 Economy). Tagged "[heartbeat] worker-done" so it
# is legible in logs and unmistakable from the bitzer poll, shaun's stuck-recovery, and the worker-stalled
# alert. It fires only when shirley is FINISHED (idle, stable across two beats) and shaun is PARKED, so
# shaun's judgment verifies the slice and hands the next - the event that replaces the old per-beat blind
# poll. It only WAKES shaun on HIS pane; it never types into shirley, and direction is shaun.md's, not ours.
readonly DEFAULT_WORKER_DONE_TRIGGER='[heartbeat] worker-done: shirley looks finished (idle, no progress across two beats - slice complete or awaiting your hand). Check her pane - verify her last slice and hand the next from MISSION.md, or send STANDBY if the queue is empty. This is an event wake; direction is yours.'
WORKER_DONE_TRIGGER="${MOSSY_HEARTBEAT_WORKER_DONE_TRIGGER:-${DEFAULT_WORKER_DONE_TRIGGER}}"

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
    wake VIA send-verified (#32) - confirmed-submitted + retried once, logged if it still fails.
    working/standby do nothing. Skipped quietly if there is no shaun pane yet.
  - shirley: classify the worker ONCE across beats (worker_verdict) and partition by state, two
    disjoint event-wakes to SHAUN's pane (never typing into shirley), each only when shaun is
    parked on a STANDBY: (#29) STALLED (a frozen spinner stable across two ticks) -> alert shaun
    his worker is wedged; (#36) DONE (idle, stable across two beats) -> wake shaun to verify the
    finished slice and hand the next. A BUSY worker does nothing (the economy win). Disjoint from
    the shaun branch (that owns a STUCK shaun) and from each other (stalled vs done), so no
    double-wake.
No timed expiry.

Env: MOSSY_STATE_DIR (.barn-panes dir), MOSSY_REPO_DIR (timmy location),
     MOSSY_HEARTBEAT_SECS (cadence, default 300), MOSSY_HEARTBEAT_TRIGGER (poll text),
     MOSSY_HEARTBEAT_STUCK_TRIGGER (stuck-recovery text), MOSSY_HEARTBEAT_WORKER_TRIGGER
     (worker-alert text), MOSSY_HEARTBEAT_WORKER_DONE_TRIGGER (worker-done text),
     MOSSY_SHAUN_FP / MOSSY_WORKER_FP (fingerprint files).
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

# send_trigger <pane> - deliver the bitzer sustain nudge and CONFIRM it submitted (#33, the last
# send-verified adoption gap). The trigger drives the ENTIRE poll loop every beat; a silently
# buffered-unsent nudge (the 06:39 race) skips one whole sustain cycle. We route it through
# send-verified.sh - same as #32's recovery wakes - so the nudge is confirmed (bitzer idle->busy)
# and retried ONCE before we give up. NO leading C-u here (unlike send_wake): beat_bitzer only
# calls this when bitzer is timmy-idle, so its input box is empty - there is no partial fragment
# to clear, and the original send_trigger sent none. We pass MOSSY_TIMMY so send-verified uses the
# SAME timmy heartbeat resolved. The ~2s verify is <1% of the 300s beat - negligible vs every
# sustain cycle actually firing. Returns send-verified's exit code so beat_bitzer logs the outcome.
send_trigger() {
  MOSSY_TIMMY="$TIMMY" "$SEND_VERIFIED" "$1" "$TRIGGER"
}

# send_wake <pane> <trigger> - deliver a recovery wake and CONFIRM it submitted (#32). Mirrors
# the proven-safe MANUAL recovery (a plain trigger + Enter - a live stuck turn observed 2026-06-11
# emits the malformed call as OUTPUT and ENDS the turn, leaving the input line empty, so no
# interrupt is needed and a plain wake recovers it), but routes the actual delivery through
# send-verified.sh so the wake cannot silently buffer-unsent (the 06:39 race) on the very path
# the recovery net depends on. We keep the leading C-u (a harmless readline line-clear, cheap
# insurance should a variant leave a partial input line) BEFORE handing off; send-verified then
# types the trigger, confirms the pane went busy via timmy, and retries ONCE on a miss. We pass
# MOSSY_TIMMY so send-verified classifies with the SAME timmy heartbeat resolved. We deliberately
# do NOT send C-c (its TUI interrupt/exit semantics are unverified). Both the #20 stuck-recovery
# and the #29 worker-alert wake SHAUN's pane through this one mechanism (different trigger text);
# neither ever sends keys to shirley. Returns send-verified's exit code: 0 submitted, nonzero
# delivery failed - so the caller logs the outcome instead of assuming the wake landed.
send_wake() {
  local pane="$1" trigger="$2"
  tmux send-keys -t "$pane" C-u
  MOSSY_TIMMY="$TIMMY" "$SEND_VERIFIED" "$pane" "$trigger"
}

# beat_bitzer - the poll nudge. Read bitzer's id, classify with timmy, nudge IFF idle (exit 0),
# otherwise skip. The idle nudge is delivered VIA send-verified (#33): confirmed-submitted +
# retried once, logged whether it took. A failed nudge degrades gracefully - we log and move on,
# never crashing the loop (this beat's poll is skipped, but the next beat self-heals). Never dies
# on a single bad beat - the loop must outlive transient trouble (a momentarily gone pane, a panes
# file not yet written).
beat_bitzer() {
  local id state rc
  id="$(bitzer_pane "$panes_file")" \
    || { log "no bitzer pane id in ${panes_file} - skip"; return 0; }
  state="$("$TIMMY" --pane "$id" 2>/dev/null)"
  rc=$?
  case "$rc" in
    0)
      if send_trigger "$id"; then
        log "bitzer idle (${id}) -> nudged + verified"
      else
        log "bitzer idle (${id}) -> nudge FAILED to submit after retry - poll skipped this beat (self-heals next beat)"
      fi
      ;;
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
    if send_wake "$id" "$STUCK_TRIGGER"; then
      log "shaun STUCK (${id}) -> stuck-recovery wake delivered + verified"
    else
      log "shaun STUCK (${id}) -> stuck-recovery wake FAILED to submit after retry - still stuck"
    fi
  fi
}

# worker_verdict - classify the WORKER (shirley) pane ONCE per beat and echo "<wid> <state>", where
# state is one of: done|stalled|alive|other. This single classification is SHARED by both worker-event
# branches and partitioned by STATE, so they are disjoint and can never double-wake. stuck-check is the
# cross-beat authority (it owns the WORKER_FP fingerprint, so its 'stuck' verdict already demands
# changed=0 - content STABLE across two beats - which IS the two-beat confirm #36 needs and the #29
# stall needs). But stuck-check collapses two different dead-stable states into one exit 20: a stalled
# frozen spinner (timmy 40, #25/#28) AND an idle-done worker (timmy 0, idle + stable + no STANDBY). So
# ONLY on that exit-20 path we re-read the now-static pane with timmy ONCE to split it back: idle(0) ->
# 'done' (a finished slice awaiting the next hand, #36), stalled(40) -> 'stalled' (a wedged turn, #29).
# Any other state -> 'alive' (working/waiting/question - genuinely advancing, no wake this slice). Echoes
# nothing (empty) when there is no shirley pane or no stuck-check. Never dies: a read failure falls toward
# 'alive', never a spurious done/stalled (a pane we cannot read is never provably finished or wedged).
worker_verdict() {
  local wid wrc trc
  [ -x "$STUCK_CHECK" ] || return 0
  wid="$(shirley_pane "$panes_file")" || return 0
  MOSSY_TIMMY="$TIMMY" "$STUCK_CHECK" --pane "$wid" --fingerprint-file "$WORKER_FP" >/dev/null 2>&1
  wrc=$?
  if [ "$wrc" -eq 20 ]; then
    "$TIMMY" --pane "$wid" >/dev/null 2>&1
    trc=$?
    case "$trc" in
      0) printf '%s done' "$wid" ;;
      40) printf '%s stalled' "$wid" ;;
      *) printf '%s other' "$wid" ;;
    esac
  else
    printf '%s alive' "$wid"
  fi
}

# beat_worker <shaun_id> <shaun_rc> <wid> <wstate> - the #29 worker-alert, now reading the SHARED
# worker_verdict. When the worker is 'stalled' (a frozen spinner stable across two ticks, #28) AND shaun
# is parked on a STANDBY (shaun_rc=10), ALERT shaun on HIS pane so his judgment drives recovery - NEVER
# typing into shirley. The shaun_rc=10 gate makes this DISJOINT from beat_shaun (which owns shaun_rc=20),
# and the 'stalled' state-gate makes it disjoint from beat_worker_done (which owns 'done') - so no branch
# can double-wake, and a busy/working shaun (rc=0) is never interrupted. Skipped QUIETLY when there is no
# worker verdict or no shaun to alert.
beat_worker() {
  local shaun_id="$1" shaun_rc="$2" wid="$3" wstate="$4"
  [ -n "$shaun_id" ] || return 0
  [ -n "$wid" ] || return 0
  if [ "$wstate" = "stalled" ] && [ "$shaun_rc" = "10" ]; then
    if send_wake "$shaun_id" "$WORKER_TRIGGER"; then
      log "shirley STUCK (${wid}) + shaun parked (${shaun_id}) -> worker-alert delivered + verified to shaun"
    else
      log "shirley STUCK (${wid}) + shaun parked (${shaun_id}) -> worker-alert FAILED to submit after retry"
    fi
  fi
}

# beat_worker_done <shaun_id> <shaun_rc> <wid> <wstate> - the #36 worker-done wake, reading the SHARED
# worker_verdict. When the worker is 'done' (idle, stable across two beats - a finished slice awaiting the
# next hand) AND shaun is parked on a STANDBY (shaun_rc=10), WAKE shaun on HIS pane so his judgment
# verifies the slice and hands the next - NEVER typing into shirley. This is the event that replaces the
# old per-beat blind poll: a BUSY worker reaches this with wstate='alive' and does NOTHING (the economy
# win). DISJOINT from beat_worker by the 'done' vs 'stalled' state-gate, and from beat_shaun by the
# shaun_rc=10 gate - so no double-wake. Skipped QUIETLY when there is no worker verdict or no shaun.
beat_worker_done() {
  local shaun_id="$1" shaun_rc="$2" wid="$3" wstate="$4"
  [ -n "$shaun_id" ] || return 0
  [ -n "$wid" ] || return 0
  if [ "$wstate" = "done" ] && [ "$shaun_rc" = "10" ]; then
    if send_wake "$shaun_id" "$WORKER_DONE_TRIGGER"; then
      log "shirley DONE (${wid}, idle x2) + shaun parked (${shaun_id}) -> worker-done wake delivered + verified to shaun"
    else
      log "shirley DONE (${wid}, idle x2) + shaun parked (${shaun_id}) -> worker-done wake FAILED to submit after retry"
    fi
  fi
}

# beat - one heartbeat: the bitzer poll nudge, then the shaun-aware and worker-aware branches. Shaun is
# classified ONCE (shaun_verdict), shared by beat_shaun (#20, owns shaun STUCK) and the two worker
# branches' STANDBY gate. The WORKER is also classified ONCE (worker_verdict), shared by beat_worker
# (#29, owns 'stalled') and beat_worker_done (#36, owns 'done'), partitioned by state so all four wakes
# are mutually disjoint and can never double-wake. Each branch is self-contained and resilient, so one
# bad branch never stops the others or the loop.
beat() {
  beat_bitzer
  local sv shaun_id shaun_rc
  sv="$(shaun_verdict)"
  read -r shaun_id shaun_rc <<<"$sv"
  beat_shaun "$shaun_id" "$shaun_rc"
  local wv wid wstate
  wv="$(worker_verdict)"
  read -r wid wstate <<<"$wv"
  beat_worker "$shaun_id" "$shaun_rc" "$wid" "$wstate"
  beat_worker_done "$shaun_id" "$shaun_rc" "$wid" "$wstate"
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
