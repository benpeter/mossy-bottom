#!/usr/bin/env bash
# heartbeat.test.sh - hermetic, launch-free test for the #20 stuck-shaun recovery branch AND the
# #29 stalled-worker alert in bin/heartbeat.sh. No claude: we drive `heartbeat.sh --once` against
# REAL throwaway tmux panes whose content is canned, with --panes pointed at a fake .barn-panes
# and the shaun/worker fingerprints at temp paths. The wake is a plain trigger + Enter (no C-c,
# slice 4), so the fixtures are plain sleep panes - they need not survive an interrupt. Torn down
# on exit.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
hb="$here/heartbeat.sh"

export TIMMY_INTERVAL="${TIMMY_INTERVAL:-0.3}" # timmy runs inside stuck-check inside heartbeat
export MOSSY_HEARTBEAT_STUCK_TRIGGER='WAKE-STUCK-XYZZY'   # distinctive marker: shaun stuck-recovery (#20)
export MOSSY_HEARTBEAT_WORKER_TRIGGER='WAKE-WORKER-XYZZY' # distinctive marker: worker-alert to shaun (#29)

tmp="$(mktemp -d "${TMPDIR:-/tmp}/heartbeat-test-XXXXXX")"
sessions=""
cleanup() {
  local s
  for s in $sessions; do tmux kill-session -t "$s" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT

pass=0
fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# A genuine idle box (timmy -> idle); the same shape the timmy/stuck-check suites use.
idle_box='\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/t | Opus 4.8 | Context: 5%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle) \xc2\xb7 \xe2\x86\x90 for agents\n'

# make_fixture <sess> <printf-content> - a plain pane showing the canned content (the wake no
# longer sends C-c, so no interrupt-survival shim is needed). Records the session for teardown.
make_fixture() {
  tmux new-session -d -s "$1" -x 80 -y 24 "printf '$2'; sleep 600" 2>/dev/null
  sessions="$sessions $1"
  sleep 0.5
}

# fake_panes <sess> - write a .barn-panes whose shaun= points at the fixture (no bitzer entry,
# so the bitzer branch just logs a skip). Echoes the panes-file path.
fake_panes() {
  local f="$tmp/panes_$1"
  printf 'shaun=%s\n' "$1" >"$f"
  printf '%s' "$f"
}

# fake_panes2 <shaun-sess> <shirley-sess> - a .barn-panes with BOTH shaun and shirley (no
# bitzer), for the #29 worker-alert cases. Echoes the panes-file path.
fake_panes2() {
  local f="$tmp/panes2_$1_$2"
  printf 'shaun=%s\nshirley=%s\n' "$1" "$2" >"$f"
  printf '%s' "$f"
}

# stalled_worker <sess> - a STATIC frozen spinner: byte-identical across timmy's samples, so
# timmy reads it stalled (exit 40, #25) and stuck-check maps it to stuck (#28). A wedged worker.
stalled_worker() {
  tmux new-session -d -s "$1" -x 80 -y 24 \
    'printf "\xe2\x97\x8f Whirring\xe2\x80\xa6 (esc to interrupt \xc2\xb7 1234 tokens)\n"; sleep 600' 2>/dev/null
  sessions="$sessions $1"
  sleep 0.5
}

# animating <sess> - an ANIMATING spinner (frame + counter change faster than timmy's INTERVAL),
# so timmy reads it busy (exit 10) -> stuck-check working. A live, advancing pane. The $(...) /
# $i / $((...)) run inside the pane's OWN shell - single quotes are deliberate.
# shellcheck disable=SC2016
animating() {
  tmux new-session -d -s "$1" -x 80 -y 24 \
    'i=0; while :; do printf "\r%s Whirring\xe2\x80\xa6 (esc to interrupt \xc2\xb7 %d tokens)" "$([ $((i%2)) = 0 ] && printf "\xe2\x97\x8f" || printf "\xe2\x97\x8b")" "$i"; i=$((i+1)); sleep 0.05; done' 2>/dev/null
  sessions="$sessions $1"
  sleep 0.5
}

# beat <panes-file> <shaun-fp> [worker-fp] - run a single heartbeat; OUT captures its log. The
# worker fp defaults to an unused path so the #20 (shaun-only) calls are byte-unaffected.
beat() { OUT="$(MOSSY_SHAUN_FP="$2" MOSSY_WORKER_FP="${3:-$tmp/unused-worker.fp}" "$hb" --once --panes "$1" 2>&1)"; }
log_has() { printf '%s\n' "$OUT" | grep -q "$1"; }
pane_has() { tmux capture-pane -p -t "$1" 2>/dev/null | grep -q "$2"; }

# ============================================================================
# STUCK: idle box, no STANDBY. Beat 1 stores fp / no nudge; beat 2 (identical, changed=0)
# -> shaun nudged. Assert BOTH the log line AND that the pane received the wake text.
# ============================================================================
ss="hbt_stuck_$$"
make_fixture "$ss" "\xe2\x8f\xba all settled now.\n${idle_box}"
pf="$(fake_panes "$ss")"
fp="$tmp/stuck.fp"

beat "$pf" "$fp"
if log_has 'shaun STUCK'; then no "stuck beat 1: no nudge yet"; else ok "stuck beat 1: no nudge yet (fp just stored)"; fi
if [ -f "$fp" ]; then ok "stuck beat 1: fingerprint file written"; else no "stuck beat 1: fingerprint file written"; fi
if pane_has "$ss" 'WAKE-STUCK-XYZZY'; then no "stuck beat 1: pane NOT yet woken"; else ok "stuck beat 1: pane NOT yet woken"; fi

beat "$pf" "$fp"
if log_has 'shaun STUCK'; then ok "stuck beat 2: heartbeat logged 'shaun STUCK -> wake'"; else no "stuck beat 2: heartbeat logged 'shaun STUCK -> wake'"; fi
sleep 0.3
if pane_has "$ss" 'WAKE-STUCK-XYZZY'; then ok "stuck beat 2: pane RECEIVED the stuck-recovery wake text"; else no "stuck beat 2: pane RECEIVED the stuck-recovery wake text"; fi

# ============================================================================
# WORKING: a genuinely BUSY pane - an ANIMATING spinner (the frame + token count change
# faster than timmy's INTERVAL), so timmy classifies it busy. This must NOT be a *static*
# spinner: post-#25 a frozen spinner reads 'stalled', and post-#28 stalled -> stuck, so a
# static fixture would (correctly) be recovered. A real working Claude pane animates
# continuously, so this faithfully represents one. Two beats -> never nudged.
# ============================================================================
sw="hbt_work_$$"
# The $(...) / $i / $((...)) run inside the pane's OWN shell (animate the spinner there), not
# this test shell - single quotes are deliberate.
# shellcheck disable=SC2016
tmux new-session -d -s "$sw" -x 80 -y 24 \
  'i=0; while :; do printf "\r%s Whirring\xe2\x80\xa6 (esc to interrupt \xc2\xb7 %d tokens)" "$([ $((i%2)) = 0 ] && printf "\xe2\x97\x8f" || printf "\xe2\x97\x8b")" "$i"; i=$((i+1)); sleep 0.05; done' 2>/dev/null
sessions="$sessions $sw"
sleep 0.5
pfw="$(fake_panes "$sw")"
fpw="$tmp/work.fp"
beat "$pfw" "$fpw"
beat "$pfw" "$fpw"
if log_has 'shaun STUCK'; then no "working: never logged stuck"; else ok "working: never logged stuck (animating spinner -> busy -> working)"; fi
if pane_has "$sw" 'WAKE-STUCK-XYZZY'; then no "working: pane never woken"; else ok "working: pane never woken"; fi

# ============================================================================
# STANDBY: idle box WITH a STANDBY line. Two beats -> never nudged (bitzer's STANDBY-wake
# owns that legit pause, not the stuck-recovery branch).
# ============================================================================
sb="hbt_standby_$$"
make_fixture "$sb" "\xe2\x8f\xba STANDBY (context) - resume monitoring shirley.\n${idle_box}"
pfb="$(fake_panes "$sb")"
fpb="$tmp/standby.fp"
beat "$pfb" "$fpb"
beat "$pfb" "$fpb"
if log_has 'shaun STUCK'; then no "standby: never logged stuck"; else ok "standby: never logged stuck (STANDBY -> not a stuck-nudge)"; fi
if pane_has "$sb" 'WAKE-STUCK-XYZZY'; then no "standby: pane never woken"; else ok "standby: pane never woken"; fi

# ============================================================================
# #29 WORKER-ALERT: stalled worker + shaun parked on STANDBY -> shaun is ALERTED on his own
# pane (worker nudge), and is NOT given the stuck-recovery wake (the two paths are disjoint).
# Beat 1 stores both fingerprints / no wake; beat 2 (worker stable -> stuck, shaun standby) fires.
# ============================================================================
wa_shaun="hbt_wa_shaun_$$"
make_fixture "$wa_shaun" "\xe2\x8f\xba STANDBY (context) - resume monitoring shirley.\n${idle_box}"
wa_shirley="hbt_wa_shirley_$$"
stalled_worker "$wa_shirley"
pfwa="$(fake_panes2 "$wa_shaun" "$wa_shirley")"

beat "$pfwa" "$tmp/wa_shaun.fp" "$tmp/wa_worker.fp"
if pane_has "$wa_shaun" 'WAKE-WORKER-XYZZY'; then no "worker-alert beat 1: shaun NOT yet alerted"; else ok "worker-alert beat 1: shaun NOT yet alerted (fps just stored)"; fi

beat "$pfwa" "$tmp/wa_shaun.fp" "$tmp/wa_worker.fp"
sleep 0.3
if log_has 'shirley STUCK'; then ok "worker-alert beat 2: heartbeat logged 'shirley STUCK -> worker-alert'"; else no "worker-alert beat 2: heartbeat logged 'shirley STUCK -> worker-alert'"; fi
if pane_has "$wa_shaun" 'WAKE-WORKER-XYZZY'; then ok "worker-alert beat 2: shaun RECEIVED the worker-alert wake"; else no "worker-alert beat 2: shaun RECEIVED the worker-alert wake"; fi
if pane_has "$wa_shaun" 'WAKE-STUCK-XYZZY'; then no "worker-alert beat 2: shaun NOT given the stuck-recovery wake (disjoint, no double-wake)"; else ok "worker-alert beat 2: shaun NOT given the stuck-recovery wake (disjoint, no double-wake)"; fi

# ============================================================================
# #29 WORKER-WORKING: an ANIMATING (busy) worker -> never an alert, whatever shaun is doing.
# Two beats against a parked shaun; the worker is always 'working', so shaun is never alerted.
# ============================================================================
ww_shaun="hbt_ww_shaun_$$"
make_fixture "$ww_shaun" "\xe2\x8f\xba STANDBY (context) - resume monitoring shirley.\n${idle_box}"
ww_shirley="hbt_ww_shirley_$$"
animating "$ww_shirley"
pfww="$(fake_panes2 "$ww_shaun" "$ww_shirley")"
beat "$pfww" "$tmp/ww_shaun.fp" "$tmp/ww_worker.fp"
beat "$pfww" "$tmp/ww_shaun.fp" "$tmp/ww_worker.fp"
if log_has 'shirley STUCK'; then no "worker-working: never logged a worker stall"; else ok "worker-working: never logged a worker stall (animating -> busy -> working)"; fi
if pane_has "$ww_shaun" 'WAKE-WORKER-XYZZY'; then no "worker-working: shaun never alerted"; else ok "worker-working: shaun never alerted"; fi

# ============================================================================
# #29 WORKER-STALLED + SHAUN-ACTIVE: a stalled worker but a BUSY shaun -> never an alert (never
# interrupt a mid-turn shaun). Shaun is an animating spinner -> stuck-check 'working', not the
# STANDBY (10) the gate requires. Two beats; shaun is never alerted.
# ============================================================================
wb_shaun="hbt_wb_shaun_$$"
animating "$wb_shaun"
wb_shirley="hbt_wb_shirley_$$"
stalled_worker "$wb_shirley"
pfwb="$(fake_panes2 "$wb_shaun" "$wb_shirley")"
beat "$pfwb" "$tmp/wb_shaun.fp" "$tmp/wb_worker.fp"
beat "$pfwb" "$tmp/wb_shaun.fp" "$tmp/wb_worker.fp"
if pane_has "$wb_shaun" 'WAKE-WORKER-XYZZY'; then no "worker-stalled+shaun-active: busy shaun never alerted/interrupted"; else ok "worker-stalled+shaun-active: busy shaun never alerted/interrupted"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
