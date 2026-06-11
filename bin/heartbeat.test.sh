#!/usr/bin/env bash
# heartbeat.test.sh - hermetic, launch-free test for the #20 stuck-shaun recovery branch AND the
# #29 stalled-worker alert in bin/heartbeat.sh. No claude: we drive `heartbeat.sh --once` against
# REAL throwaway tmux panes whose content is canned, with --panes pointed at a fake .barn-panes
# and the shaun/worker fingerprints at temp paths. Torn down on exit.
#
# #32: the recovery wakes are now delivered through send-verified, which CONFIRMS the pane went
# busy (the turn started) and retries once on a miss. So a wake-EXPECTING fixture must transition
# idle->busy on input (make_wakeable): static until the wake's Enter, then an ever-changing loop,
# which is exactly the submission send-verified confirms. A wake whose delivery should FAIL uses
# make_counter: it stays visually static (always idle, so send-verified never sees busy -> retries
# then gives up) while recording every delivered line to a file, so the file's line count is the
# number of deliveries made. The no-wake cases (working/standby/worker-working/worker-active) never
# deliver, so they keep their plain static fixtures.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
hb="$here/heartbeat.sh"

export TIMMY_INTERVAL="${TIMMY_INTERVAL:-0.3}" # timmy runs inside stuck-check AND send-verified inside heartbeat
export SV_POLLS="${SV_POLLS:-3}"               # send-verified polls per delivery attempt (bound the failure path)
export SV_SETTLE="${SV_SETTLE:-0.2}"           # send-verified text->Enter settle (short for a fast suite)
export MOSSY_HEARTBEAT_TRIGGER='NUDGE-BITZER-XYZZY'      # distinctive marker: bitzer sustain nudge (#33)
export MOSSY_HEARTBEAT_STUCK_TRIGGER='WAKE-STUCK-XYZZY'   # distinctive marker: shaun stuck-recovery (#20)
export MOSSY_HEARTBEAT_WORKER_TRIGGER='WAKE-WORKER-XYZZY' # distinctive marker: worker-alert to shaun (#29)
export MOSSY_HEARTBEAT_WORKER_DONE_TRIGGER='WAKE-DONE-XYZZY' # distinctive marker: worker-done wake to shaun (#36)

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

# make_fixture <sess> <printf-content> - a plain STATIC pane showing the canned content. Used by
# the NO-wake cases (working/standby/...), which never deliver, so the pane need only hold a
# classifiable state. Records the session for teardown.
make_fixture() {
  tmux new-session -d -s "$1" -x 80 -y 24 "printf '$2'; sleep 600" 2>/dev/null
  sessions="$sessions $1"
  sleep 0.5
}

# make_wakeable <sess> <printf-content> - a WAKE-EXPECTING pane: it shows the canned content and
# blocks on `read` (so it is idle/classifiable until woken), then on receiving the wake's line it
# loops emitting ever-changing output (-> busy). That idle->busy transition is exactly what
# send-verified confirms, so a wake delivered here verifies as submitted. The loop body runs in
# the FIXTURE shell ($x / $RANDOM are deliberately not expanded here).
make_wakeable() {
  local cmd="printf '$2'; read x; while :; do printf 'tick %s\\n' \"\$RANDOM\"; sleep 0.05; done"
  tmux new-session -d -s "$1" -x 80 -y 24 "$cmd" 2>/dev/null
  sessions="$sessions $1"
  sleep 0.5
}

# make_counter <sess> <printf-content> <logfile> - a DELIVERY-FAILING pane: it shows the canned
# content and stays VISUALLY static forever (timmy always idle), so send-verified never sees a
# busy transition - it retries once, then reports failure. Meanwhile it reads every delivered
# (Enter-terminated) line and APPENDS it to <logfile> WITHOUT touching the display, so the file's
# line count is exactly the number of deliveries send-verified made. clear_input's C-u/BSpace
# carry no newline, so they never add a phantom line.
make_counter() {
  local cmd="printf '$2'; while IFS= read -r x; do printf '%s\\n' \"\$x\" >> '$3'; done"
  tmux new-session -d -s "$1" -x 80 -y 24 "$cmd" 2>/dev/null
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

# fake_panes_bitzer <sess> - write a .barn-panes whose bitzer= points at the fixture (no shaun, so
# the shaun-aware branches return quietly). Echoes the panes-file path. For the #33 bitzer cases.
fake_panes_bitzer() {
  local f="$tmp/panesb_$1"
  printf 'bitzer=%s\n' "$1" >"$f"
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
# STUCK (#20, delivered AND verified via send-verified, #32): a wakeable pane - idle box, no
# STANDBY, blocked on read. Beat 1 stores fp / no nudge; beat 2 (identical, changed=0) -> shaun
# STUCK -> stuck-recovery wake delivered, the pane transitions idle->busy, and send-verified
# CONFIRMS it. The success log line ("delivered + verified") is the proof the busy transition was
# observed; we also assert timmy now reads the pane busy. (The wake TEXT scrolls off as the busy
# loop runs, so the verified-delivery LOG, not a pane-text grep, is the robust signal here.)
# ============================================================================
ss="hbt_stuck_$$"
make_wakeable "$ss" "\xe2\x8f\xba all settled now.\n${idle_box}"
pf="$(fake_panes "$ss")"
fp="$tmp/stuck.fp"

beat "$pf" "$fp"
if log_has 'shaun STUCK'; then no "stuck beat 1: no nudge yet"; else ok "stuck beat 1: no nudge yet (fp just stored)"; fi
if [ -f "$fp" ]; then ok "stuck beat 1: fingerprint file written"; else no "stuck beat 1: fingerprint file written"; fi
if pane_has "$ss" 'WAKE-STUCK-XYZZY'; then no "stuck beat 1: pane NOT yet woken"; else ok "stuck beat 1: pane NOT yet woken"; fi

beat "$pf" "$fp"
if log_has 'shaun STUCK'; then ok "stuck beat 2: heartbeat logged 'shaun STUCK'"; else no "stuck beat 2: heartbeat logged 'shaun STUCK'"; fi
if log_has 'delivered + verified'; then ok "stuck beat 2: wake DELIVERED + VERIFIED (send-verified saw the idle->busy submission)"; else no "stuck beat 2: wake delivered + verified ($OUT)"; fi
if log_has 'FAILED'; then no "stuck beat 2: must NOT log a delivery failure"; else ok "stuck beat 2: no delivery failure logged"; fi
"$here/../timmy/bin/timmy" --pane "$ss" >/dev/null 2>&1; brc=$?
if [ "$brc" -eq 10 ]; then ok "stuck beat 2: pane is now BUSY (the wake started a turn)"; else no "stuck beat 2: pane should be busy after a verified wake (timmy rc=$brc)"; fi

# ============================================================================
# RETRY / DELIVERY FAILURE (#32): a stuck shaun whose pane NEVER goes busy (make_counter stays
# visually static -> timmy idle on every poll). send-verified's first delivery does not 'take',
# so it CLEARS and RETRIES once, then reports failure. The fixture records each delivered line to
# a file, so the file's line count == deliveries: exactly 2 (initial + one retry). The heartbeat
# logs a CLEAR failure, NOT a false success. This is the recovery-net's own delivery being
# caught when it cannot submit, instead of silently no-op'ing (the whole point of #32).
# ============================================================================
rs="hbt_retry_$$"
rgot="$tmp/retry_deliveries.log"
make_counter "$rs" "\xe2\x8f\xba all settled now.\n${idle_box}" "$rgot"
rpf="$(fake_panes "$rs")"
rfp="$tmp/retry.fp"

beat "$rpf" "$rfp"   # beat 1: store fp, no wake
if [ -s "$rgot" ]; then no "retry beat 1: no delivery yet"; else ok "retry beat 1: no delivery yet (fp just stored)"; fi

beat "$rpf" "$rfp"   # beat 2: STUCK -> deliver, miss, retry once, fail
if log_has 'shaun STUCK'; then ok "retry beat 2: heartbeat logged 'shaun STUCK'"; else no "retry beat 2: heartbeat logged 'shaun STUCK'"; fi
if log_has 'FAILED to submit after retry'; then ok "retry beat 2: clear delivery-FAILED log (not a silent no-op)"; else no "retry beat 2: expected a clear FAILED log ($OUT)"; fi
if log_has 'delivered + verified'; then no "retry beat 2: must NOT claim a verified success"; else ok "retry beat 2: did not falsely claim success"; fi
dn="$(grep -c . "$rgot" 2>/dev/null || printf 0)"
if [ "$dn" -eq 2 ]; then ok "retry beat 2: delivered EXACTLY twice (initial + one retry)"; else no "retry beat 2: expected 2 deliveries, got $dn"; fi

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
make_wakeable "$wa_shaun" "\xe2\x8f\xba STANDBY (context) - resume monitoring shirley.\n${idle_box}"
wa_shirley="hbt_wa_shirley_$$"
stalled_worker "$wa_shirley"
pfwa="$(fake_panes2 "$wa_shaun" "$wa_shirley")"

beat "$pfwa" "$tmp/wa_shaun.fp" "$tmp/wa_worker.fp"
if pane_has "$wa_shaun" 'WAKE-WORKER-XYZZY'; then no "worker-alert beat 1: shaun NOT yet alerted"; else ok "worker-alert beat 1: shaun NOT yet alerted (fps just stored)"; fi

beat "$pfwa" "$tmp/wa_shaun.fp" "$tmp/wa_worker.fp"
if log_has 'shirley STUCK'; then ok "worker-alert beat 2: heartbeat logged 'shirley STUCK'"; else no "worker-alert beat 2: heartbeat logged 'shirley STUCK'"; fi
if log_has 'worker-alert delivered + verified'; then ok "worker-alert beat 2: alert DELIVERED + VERIFIED to shaun (idle->busy submission confirmed)"; else no "worker-alert beat 2: alert delivered + verified ($OUT)"; fi
if log_has 'stuck-recovery'; then no "worker-alert beat 2: shaun NOT given the stuck-recovery wake (disjoint, no double-wake)"; else ok "worker-alert beat 2: shaun NOT given the stuck-recovery wake (disjoint, no double-wake)"; fi

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

# ============================================================================
# #33 BITZER TRIGGER delivered AND verified: an idle bitzer (wakeable pane) is nudged; the nudge
# transitions it idle->busy and send-verified CONFIRMS it. ONE beat suffices - the trigger fires
# on the first idle classification (no cross-beat fingerprint). The verified-delivery LOG is the
# robust signal (the nudge text scrolls off as the busy loop runs); we also assert timmy now busy.
# ============================================================================
bz="hbt_bz_$$"
make_wakeable "$bz" "\xe2\x8f\xba waiting for input.\n${idle_box}"
pfbz="$(fake_panes_bitzer "$bz")"
beat "$pfbz" "$tmp/bz_shaun.fp"
if log_has 'bitzer idle'; then ok "bitzer-trigger: idle bitzer classified + nudged"; else no "bitzer-trigger: idle bitzer nudged ($OUT)"; fi
if log_has 'nudged + verified'; then ok "bitzer-trigger: nudge DELIVERED + VERIFIED (idle->busy submission confirmed)"; else no "bitzer-trigger: nudge delivered + verified ($OUT)"; fi
if log_has 'FAILED'; then no "bitzer-trigger: must NOT log a delivery failure"; else ok "bitzer-trigger: no delivery failure logged"; fi
"$here/../timmy/bin/timmy" --pane "$bz" >/dev/null 2>&1; bzrc=$?
if [ "$bzrc" -eq 10 ]; then ok "bitzer-trigger: pane is now BUSY (the nudge started the poll)"; else no "bitzer-trigger: pane should be busy after a verified nudge (timmy rc=$bzrc)"; fi

# ============================================================================
# #33 BITZER TRIGGER retry / delivery failure: an idle bitzer whose pane never goes busy
# (make_counter stays visually static -> timmy idle on every poll). send-verified's first delivery
# does not take -> clear + retry once -> fail. The fixture records each delivered line to a file,
# so the count == 2 (initial + one retry). The heartbeat logs a CLEAR failure and degrades
# gracefully (the loop is not crashed); the next beat self-heals.
# ============================================================================
bzr="hbt_bzr_$$"
bzgot="$tmp/bz_deliveries.log"
make_counter "$bzr" "\xe2\x8f\xba waiting for input.\n${idle_box}" "$bzgot"
pfbzr="$(fake_panes_bitzer "$bzr")"
beat "$pfbzr" "$tmp/bzr_shaun.fp"
if log_has 'nudge FAILED to submit after retry'; then ok "bitzer-retry: clear delivery-FAILED log (not a silent no-op)"; else no "bitzer-retry: expected a clear FAILED log ($OUT)"; fi
if log_has 'nudged + verified'; then no "bitzer-retry: must NOT claim a verified success"; else ok "bitzer-retry: did not falsely claim success"; fi
bzdn="$(grep -c . "$bzgot" 2>/dev/null || printf 0)"
if [ "$bzdn" -eq 2 ]; then ok "bitzer-retry: delivered EXACTLY twice (initial + one retry)"; else no "bitzer-retry: expected 2 deliveries, got $bzdn"; fi

# ============================================================================
# #33 BITZER GATING preserved: a BUSY bitzer (animating spinner) is NEVER nudged - the trigger
# stays gated on idle, so send-verified is never even invoked mid-turn (no stacking).
# ============================================================================
bzb="hbt_bzb_$$"
animating "$bzb"
pfbzb="$(fake_panes_bitzer "$bzb")"
beat "$pfbzb" "$tmp/bzb_shaun.fp"
if log_has 'skip (no mid-turn stacking)'; then ok "bitzer-gating: busy bitzer SKIPPED (no mid-turn nudge)"; else no "bitzer-gating: busy bitzer skipped ($OUT)"; fi
if log_has 'nudged'; then no "bitzer-gating: busy bitzer must NOT be nudged"; else ok "bitzer-gating: busy bitzer never nudged"; fi

# ============================================================================
# #36 WORKER-DONE event wake: a FINISHED worker (a static idle box, NO STANDBY marker - shirley does
# not print STANDBY) + shaun parked on a STANDBY -> shaun is WOKEN on his own pane with the worker-done
# nudge. Beat 1 stores both fingerprints / NO wake (a single idle beat is a transient idle - the
# two-beat confirm is unmet), beat 2 (worker stable-idle, shaun stable-standby) fires. The wake is
# DISJOINT from #29 (no 'worker-alert') and #20 (no 'stuck-recovery'). shaun is make_wakeable so the
# idle->busy submission verifies; the worker is a plain static idle box (stays idle/done throughout).
# ============================================================================
wd_shaun="hbt_wd_shaun_$$"
make_wakeable "$wd_shaun" "\xe2\x8f\xba STANDBY (context) - resume monitoring shirley.\n${idle_box}"
wd_shirley="hbt_wd_shirley_$$"
make_fixture "$wd_shirley" "$idle_box"
pfwd="$(fake_panes2 "$wd_shaun" "$wd_shirley")"

beat "$pfwd" "$tmp/wd_shaun.fp" "$tmp/wd_worker.fp"   # beat 1: store fps, transient one-beat idle -> NO wake
if log_has 'shirley DONE'; then no "worker-done beat 1: one-beat idle must NOT wake (two-beat confirm unmet)"; else ok "worker-done beat 1: transient one-beat idle NOT woken (fps just stored)"; fi
if pane_has "$wd_shaun" 'WAKE-DONE-XYZZY'; then no "worker-done beat 1: shaun NOT yet woken"; else ok "worker-done beat 1: shaun NOT yet woken"; fi

beat "$pfwd" "$tmp/wd_shaun.fp" "$tmp/wd_worker.fp"   # beat 2: worker idle x2 + shaun standby -> wake
if log_has 'shirley DONE'; then ok "worker-done beat 2: heartbeat logged 'shirley DONE' (idle confirmed across two beats)"; else no "worker-done beat 2: heartbeat logged 'shirley DONE' ($OUT)"; fi
if log_has 'worker-done wake delivered + verified'; then ok "worker-done beat 2: wake DELIVERED + VERIFIED to shaun (idle->busy submission confirmed)"; else no "worker-done beat 2: wake delivered + verified ($OUT)"; fi
if log_has 'worker-alert'; then no "worker-done beat 2: shaun NOT given the #29 worker-alert (disjoint, done != stalled)"; else ok "worker-done beat 2: shaun NOT given the #29 worker-alert (disjoint, done != stalled)"; fi
if log_has 'stuck-recovery'; then no "worker-done beat 2: shaun NOT given the #20 stuck-recovery (disjoint)"; else ok "worker-done beat 2: shaun NOT given the #20 stuck-recovery (disjoint)"; fi
if log_has 'FAILED'; then no "worker-done beat 2: must NOT log a delivery failure"; else ok "worker-done beat 2: no delivery failure logged"; fi

# ============================================================================
# #36 WORKER-BUSY: an ANIMATING (busy) worker + shaun parked on STANDBY -> NEVER a done-wake, whatever
# shaun is doing. This is the economy win: a worker mid-slice is busy, not done, so shaun stays parked
# (no turn, no tokens). Two beats; shaun is never woken with the done nudge.
# ============================================================================
wbz_shaun="hbt_wbz_shaun_$$"
make_fixture "$wbz_shaun" "\xe2\x8f\xba STANDBY (context) - resume monitoring shirley.\n${idle_box}"
wbz_shirley="hbt_wbz_shirley_$$"
animating "$wbz_shirley"
pfwbz="$(fake_panes2 "$wbz_shaun" "$wbz_shirley")"
beat "$pfwbz" "$tmp/wbz_shaun.fp" "$tmp/wbz_worker.fp"
beat "$pfwbz" "$tmp/wbz_shaun.fp" "$tmp/wbz_worker.fp"
if log_has 'shirley DONE'; then no "worker-busy: a busy worker is never 'done' (the economy win)"; else ok "worker-busy: busy worker never logged done (animating -> busy -> no wake: the economy win)"; fi
if pane_has "$wbz_shaun" 'WAKE-DONE-XYZZY'; then no "worker-busy: shaun never woken"; else ok "worker-busy: shaun never woken (busy worker = no event)"; fi

# ============================================================================
# #36 WORKER-DONE + SHAUN-ACTIVE: a finished (idle) worker but a BUSY shaun -> NEVER a wake (never
# interrupt a mid-turn shaun; the done-wake gates on shaun PARKED on a STANDBY). Shaun is an animating
# spinner -> stuck-check 'working' (rc 0), not the STANDBY (10) the gate requires. Two beats; shaun is
# never woken even though the worker is genuinely done.
# ============================================================================
wda_shaun="hbt_wda_shaun_$$"
animating "$wda_shaun"
wda_shirley="hbt_wda_shirley_$$"
make_fixture "$wda_shirley" "$idle_box"
pfwda="$(fake_panes2 "$wda_shaun" "$wda_shirley")"
beat "$pfwda" "$tmp/wda_shaun.fp" "$tmp/wda_worker.fp"
beat "$pfwda" "$tmp/wda_shaun.fp" "$tmp/wda_worker.fp"
if log_has 'shirley DONE'; then no "worker-done+shaun-active: a busy shaun is never woken (done-wake gates on STANDBY)"; else ok "worker-done+shaun-active: busy shaun never woken/interrupted (done-wake gates on STANDBY)"; fi
if pane_has "$wda_shaun" 'WAKE-DONE-XYZZY'; then no "worker-done+shaun-active: busy shaun never woken"; else ok "worker-done+shaun-active: busy shaun never woken"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
