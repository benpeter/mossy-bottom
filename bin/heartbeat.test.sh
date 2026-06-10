#!/usr/bin/env bash
# heartbeat.test.sh - hermetic, launch-free test for the #20 stuck-shaun recovery branch in
# bin/heartbeat.sh. No claude: we drive `heartbeat.sh --once` against REAL throwaway tmux
# panes whose content is canned, with --panes pointed at a fake .barn-panes and the shaun
# fingerprint at a temp path. The fixture panes ignore SIGINT and re-sleep, so they survive
# the wake's C-c and we can assert the wake text landed. Panes torn down on exit.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
hb="$here/heartbeat.sh"

export TIMMY_INTERVAL="${TIMMY_INTERVAL:-0.3}" # timmy runs inside stuck-check inside heartbeat
export MOSSY_HEARTBEAT_STUCK_TRIGGER='WAKE-STUCK-XYZZY' # a distinctive marker to assert on

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

# make_fixture <sess> <printf-content> - a pane that ignores INT and re-sleeps (so it survives
# the wake's C-c), showing the canned content. Records the session for teardown.
make_fixture() {
  tmux new-session -d -s "$1" -x 80 -y 24 "trap '' INT; printf '$2'; while :; do sleep 600; done" 2>/dev/null
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

# beat <panes-file> <fp> - run a single heartbeat; OUT captures its log.
beat() { OUT="$(MOSSY_SHAUN_FP="$2" "$hb" --once --panes "$1" 2>&1)"; }
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
# WORKING: a spinner (busy). Two beats -> never nudged.
# ============================================================================
sw="hbt_work_$$"
make_fixture "$sw" "\xe2\x97\x8f Whirring\xe2\x80\xa6 (esc to interrupt \xc2\xb7 1.2k tokens)"
pfw="$(fake_panes "$sw")"
fpw="$tmp/work.fp"
beat "$pfw" "$fpw"
beat "$pfw" "$fpw"
if log_has 'shaun STUCK'; then no "working: never logged stuck"; else ok "working: never logged stuck (spinner -> working)"; fi
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
