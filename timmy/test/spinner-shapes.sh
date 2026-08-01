#!/bin/bash
# Drives has_spinner's matcher over status lines Claude Code actually renders.
#
#   timmy/test/spinner-shapes.sh
#
# WHY THIS EXISTS. On 2026-08-01 a worker 25 minutes and 76.7k tokens into a slice, with a
# live spinner on screen, was classified IDLE three times out of three. The verb in the
# matcher was `[A-Za-z]+`, one word, and her line read `● Topsy-turvying…`: the pattern
# matched `Topsy`, then required the ellipsis immediately and met a hyphen.
#
# THE FAILURE DIRECTION IS WHAT MAKES IT WORTH A SUITE. During a tool call the idle box and
# the idle suffix are BOTH true, so the spinner is the only discriminator left. When it
# misses, timmy has no signal and returns `idle` rather than `unknown`, so --await answers
# wrongly, the heartbeat's worker-done fires on a working worker, and a driver trusting the
# verdict clears her and re-hands mid-slice.
#
# The comment above the matcher said "verb-agnostic" and listed single words. It was
# verb-agnostic FOR SINGLE WORDS, and the comment is what a reader checks instead of the
# pattern.
set -uo pipefail
PAT='^[[:space:]]*[^ -~]+ +[A-Za-z]+(…|\.\.\.).*\([^)]*(esc|[0-9])'
fails=0

check() { # <expected 0|1> <name> <line>
  local got; got=$(printf '%s\n' "$3" | LC_ALL=C grep -cE "$PAT")
  if [ "$got" -eq "$1" ]; then printf '  ok    %s\n' "$2"
  else printf '  FAIL  %s (matched %s, wanted %s)\n' "$2" "$got" "$1"; fails=$((fails+1)); fi
}

echo "has_spinner shapes:"
check 1 "a single-word gerund"        '● Leavening… (3m 1s · ↓ 9k tokens · esc to interrupt)'
check 1 "A HYPHENATED GERUND"         '● Topsy-turvying… (25m 7s · ↓ 76.7k tokens · still thinking with xhigh effort)'
check 1 "a long single word"          '● Razzmatazzing… (11m 7s · ↓ 22.0k tokens)'
check 1 "the esc suffix form"         '● Warping… (8s · ↓ 419 tokens · esc to interrupt)'
# GAP 7: the ^ anchor exists so prose MENTIONING a spinner is not read as one. The hyphen
# fix must not reintroduce it.
check 0 "prose mid-line is not a spinner" '  - ● Whirring… mentioned in a report (see 2 above)'
check 0 "no parenthetical is not a spinner" '● Thinking…'
check 0 "plain prose"                 'the pane was idle and nothing was running'

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
