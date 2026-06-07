#!/usr/bin/env bash
# timmy live check - prove the classifier against a REAL Claude Code pane, not a
# synthetic printf fixture. Spawns a throwaway claude in a detached tmux session,
# settles it to its idle box, classifies (expect idle), sends a prompt to make it
# work, classifies again (expect busy), then tears everything down.
#
# Requires a real `claude` on PATH and working auth. NOT part of run.sh, which
# stays hermetic. Run manually: test/live-check.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
timmy="$here/../bin/timmy"

sess="timmy_live_$$"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/timmy-live-XXXXXX")"

# Always tear down the throwaway session and scratch dir on exit.
trap 'tmux kill-session -t "$sess" 2>/dev/null; rm -rf "$workdir"' EXIT

rule() { printf -- '------------------------------------------------------------\n'; }
show() { printf '\n=== %s ===\n' "$1"; }

# Boot a clean claude (scrub the parent session's CLAUDE* vars so it does not
# think it is nested), targeted at a fresh untrusted cwd.
show "spawning real claude 2.x in detached tmux ($sess, cwd $workdir)"
tmux new-session -d -s "$sess" -x 100 -y 30 -c "$workdir" \
  "env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT \
       -u CLAUDE_CODE_EXECPATH -u AI_AGENT -u CLAUDE_EFFORT \
   claude --dangerously-skip-permissions; echo TIMMY_CLAUDE_EXITED; sleep 600"

# Settle loop. When the trust gate appears, classify it live (it is a real
# waiting-input menu) BEFORE accepting it, then accept and wait for the idle box.
settled=0
gate_seen=0
wi_word=""; wi_code=""
for _ in $(seq 1 40); do
  sleep 1
  frame="$(tmux capture-pane -p -t "$sess" 2>/dev/null)"
  if printf '%s\n' "$frame" | grep -q 'trust this folder'; then
    if [ "$gate_seen" -eq 0 ]; then
      gate_seen=1
      show "live trust-gate frame (a real waiting-input menu, verbatim)"
      rule; tmux capture-pane -p -t "$sess"; rule
      show "timmy on the live trust gate"
      wi_json="$(TIMMY_INTERVAL=0.5 "$timmy" --pane "$sess" --json)"
      wi_word="$(TIMMY_INTERVAL=0.5 "$timmy" --pane "$sess")"; wi_code=$?
      printf 'json: %s\n' "$wi_json"
      printf 'word: %s   exit: %s\n' "$wi_word" "$wi_code"
    fi
    tmux send-keys -t "$sess" Enter   # accept the trust gate (option 1)
    continue
  fi
  if printf '%s\n' "$frame" | LC_ALL=C grep -q '← for agents'; then
    settled=1; break
  fi
done

if [ "$settled" -ne 1 ]; then
  show "FAILED TO SETTLE - last live frame"
  tmux capture-pane -p -t "$sess" 2>/dev/null
  echo
  echo "RESULT: could not reach a live idle box (see frame above)."
  exit 1
fi

show "live idle frame (verbatim capture-pane)"
rule; tmux capture-pane -p -t "$sess"; rule

show "timmy on the live idle pane"
idle_json="$("$timmy" --pane "$sess" --json)"; idle_code=$?
idle_word="$("$timmy" --pane "$sess")";
printf 'json: %s\n' "$idle_json"
printf 'word: %s   exit: %s\n' "$idle_word" "$idle_code"

# Now make it work: send a prompt that streams for a few seconds.
show "sending a prompt to make the session work"
prompt="Write a detailed six-paragraph explanation of how tmux capture-pane renders a pane. Take your time and be thorough."
tmux send-keys -l -t "$sess" -- "$prompt"
sleep 0.5
tmux send-keys -t "$sess" Enter
sleep 1   # let generation start (spinner appears, output begins to stream)

show "live busy frame (verbatim capture-pane)"
rule; tmux capture-pane -p -t "$sess"; rule

show "timmy on the live working pane"
busy_json="$(TIMMY_INTERVAL=0.5 "$timmy" --pane "$sess" --json)"; busy_code=$?
busy_word="$(TIMMY_INTERVAL=0.5 "$timmy" --pane "$sess")"
printf 'json: %s\n' "$busy_json"
printf 'word: %s   exit: %s\n' "$busy_word" "$busy_code"

show "verdict"
fail=0
if [ "$gate_seen" -eq 1 ]; then
  if [ "$wi_word" = "waiting-input" ] && [ "$wi_code" -eq 20 ]; then
    echo "ok   - live trust gate classified waiting-input"
  else
    echo "FAIL - live waiting-input (got '$wi_word' exit $wi_code)"; fail=1
  fi
else
  echo "SKIP - trust gate did not appear (cwd already trusted)"
fi
if [ "$idle_word" = "idle" ] && [ "$idle_code" -eq 0 ]; then
  echo "ok   - live idle box classified idle"
else
  echo "FAIL - live idle"; fail=1
fi
if [ "$busy_word" = "busy" ] && [ "$busy_code" -eq 10 ]; then
  echo "ok   - live working pane classified busy"
else
  echo "FAIL - live busy"; fail=1
fi

echo
if [ "$fail" -eq 0 ]; then echo "LIVE PROOF PASSED"; else echo "LIVE PROOF FAILED"; fi
exit "$fail"
