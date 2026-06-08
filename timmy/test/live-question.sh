#!/usr/bin/env bash
# timmy live question check - prove the `question` state against a REAL Claude
# Code pane. Spawns a throwaway claude, drives it into a turn that ends on a
# question, and asserts timmy reads question. Then fires a multi-line turn to
# expose whether the "last ⏺ line ends in '?'" heuristic survives real output.
#
# Requires a real `claude` on PATH and working auth. Separate from the hermetic
# run.sh. Run manually: test/live-question.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
timmy="$here/../bin/timmy"

sess="timmy_liveq_$$"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/timmy-liveq-XXXXXX")"
trap 'tmux kill-session -t "$sess" 2>/dev/null; rm -rf "$workdir"' EXIT

rule() { printf -- '------------------------------------------------------------\n'; }
show() { printf '\n=== %s ===\n' "$1"; }

classify()      { TIMMY_INTERVAL=0.4 "$timmy" --pane "$sess"; }
classify_json() { TIMMY_INTERVAL=0.4 "$timmy" --pane "$sess" --json; }

send_prompt() {  # compose then submit (smoke-test.md sections 4-6)
  tmux send-keys -l -t "$sess" -- "$1"
  sleep 0.5
  tmux send-keys -t "$sess" Enter
}

# Wait for a turn: first until timmy reports busy, then until it stops.
await_turn() {
  local w
  for _ in $(seq 1 20); do
    [ "$(classify)" = "busy" ] && break
    sleep 1
  done
  for _ in $(seq 1 90); do
    w="$(classify)"
    if [ "$w" != "busy" ]; then printf '%s\n' "$w"; return 0; fi
    sleep 1
  done
  printf 'timeout\n'; return 1
}

show "spawning real claude in detached tmux ($sess)"
tmux new-session -d -s "$sess" -x 100 -y 30 -c "$workdir" \
  "env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT \
       -u CLAUDE_CODE_EXECPATH -u AI_AGENT -u CLAUDE_EFFORT \
   claude --dangerously-skip-permissions; sleep 600"

settled=0
for _ in $(seq 1 40); do
  sleep 1
  frame="$(tmux capture-pane -p -t "$sess" 2>/dev/null)"
  if printf '%s\n' "$frame" | grep -q 'trust this folder'; then
    tmux send-keys -t "$sess" Enter; continue
  fi
  if printf '%s\n' "$frame" | LC_ALL=C grep -q '← for agents'; then settled=1; break; fi
done
if [ "$settled" -ne 1 ]; then
  show "FAILED TO SETTLE"; tmux capture-pane -p -t "$sess"; exit 1
fi

fail=0

# --- case 1: a turn that ends on a question -> expect question ---
show "case 1: driving a single-question turn"
send_prompt "Ask me exactly one short clarifying question about what I want to build. Reply with ONLY that question on a single line ending in a question mark - no preamble, no options, nothing after it."
q1="$(await_turn)"
show "case 1 settled frame (verbatim)"
rule; tmux capture-pane -p -t "$sess"; rule
show "timmy on case 1"
j1="$(classify_json)"; w1="$(classify)"; c1=$?
printf 'json: %s\n' "$j1"
printf 'word: %s   exit: %s   (await_turn saw: %s)\n' "$w1" "$c1" "$q1"
if [ "$w1" = "question" ] && [ "$c1" -eq 30 ]; then
  echo "ok   - live single-question turn classified question"
else
  echo "FAIL - live question (got '$w1' exit $c1)"; fail=1
fi

# --- case 2: a multi-line turn (content THEN a continuation-line question) ---
show "case 2: driving a multi-line turn (list, then a trailing question)"
send_prompt "List two short bullet points about tmux, then on a new final line ask me which one I want explained, ending in a question mark."
q2="$(await_turn)"
show "case 2 settled frame (verbatim)"
rule; tmux capture-pane -p -t "$sess"; rule
show "timmy on case 2 (multi-line: question is an indented continuation line)"
j2="$(classify_json)"; w2="$(classify)"; c2=$?
printf 'json: %s\n' "$j2"
printf 'word: %s   exit: %s   (await_turn saw: %s)\n' "$w2" "$c2" "$q2"
if [ "$w2" = "question" ] && [ "$c2" -eq 30 ]; then
  echo "ok   - live multi-line turn classified question"
else
  echo "FAIL - live multi-line question (got '$w2' exit $c2)"; fail=1
fi

show "verdict"
if [ "$fail" -eq 0 ]; then echo "LIVE QUESTION PROOF PASSED"; else echo "LIVE QUESTION PROOF FAILED"; fi
exit "$fail"
