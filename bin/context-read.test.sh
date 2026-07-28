#!/usr/bin/env bash
# context-read.test.sh - hermetic, launch-free tests for bin/context-read.sh.
# Every case feeds footer text through --parse: no tmux, no live pane, no network.
#
# The load-bearing case is the MODERN footer. Claude's footer used to name the context
# ("Context: 41%"); it now renders it as a filled/empty bar followed by the percent and
# the window size ("▓▓▓░░░░░ 37% 1M"), with no label anywhere. A label-only matcher reads
# that as unavailable (exit 64), and bitzer's wiring treats 64 as "skip the check" - so the
# reactive self-compact silently never fires and the pane walks to the uncurated
# auto-compact wall. Observed live: bitzer at 91% with the gauge answering 64.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cr="$here/context-read.sh"

pass=0
fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# case <footer-text> <want-code> <want-stdout> <label>
# Runs --parse on stdin and asserts BOTH the exit code and the printed verdict, so a
# right-code/wrong-percent read cannot pass.
case_parse() {
  local text="$1" want_code="$2" want_out="$3" label="$4" out code
  out="$(printf '%s\n' "$text" | "$cr" --parse 2>/dev/null)"
  code=$?
  if [ "$code" -eq "$want_code" ] && [ "$out" = "$want_out" ]; then
    ok "$label"
  else
    no "$label (exit $code want $want_code; stdout '$out' want '$want_out')"
  fi
}

# --- MODERN footer: bar + percent + window size, no label. The bar is the shape anchor. ---

modern_footer() {
  # $1 = bar, $2 = percent. Mirrors the real three-row footer: separator, status row
  # (model, cwd, branch, bar, percent, window), permissions row.
  printf '%s\n' \
    '──────────────────────────────────────────────────────────────────' \
    "  Opus 5   ~/dev/adobe/cloudadoption/contitires-mossy   main   $1 $2% 1M" \
    '  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents'
}

case_parse "$(modern_footer '▓▓▓▓▓▓▓░' 91)" 10 "compact 91" \
  "modern footer 91% (the live bitzer read) -> compact, pct 91"

case_parse "$(modern_footer '▓▓▓░░░░░' 37)" 0 "ok 37" \
  "modern footer 37% -> ok, pct 37"

case_parse "$(modern_footer '░░░░░░░░' 0)" 0 "ok 0" \
  "modern footer 0% (a freshly relaunched pane) -> ok, pct 0"

case_parse "$(modern_footer '▓▓▓▓▓░░░' 70)" 10 "compact 70" \
  "modern footer at the threshold boundary (70, >=) -> compact"

# The narrow footer truncates the status row with an ellipsis, so the bar can appear with
# no percent behind it. No percent means no reading: unavailable, never a guessed number.
case_parse "$(printf '%s\n' '  Opus 5   ~/dev/adobe   main   ▓…' '  ⏵⏵ bypass permissions on')" \
  64 "" "modern footer truncated to a bare bar (no percent) -> unavailable"

# --- LEGACY footer: the labelled form must keep working (regression guard). ---

case_parse "$(printf '%s\n' '  Context: 42%' '  ⏵⏵ bypass permissions on')" 0 "ok 42" \
  "legacy 'Context: 42%' -> ok, pct 42 (regression)"

case_parse "$(printf '%s\n' '  Ctx 82%' '  ⏵⏵ bypass permissions on')" 10 "compact 82" \
  "legacy narrow 'Ctx 82%' -> compact, pct 82 (regression)"

# --- Position anchoring survives the new shape: a bar-and-percent sitting in CONTENT
# above the real footer must not beat it. The footer is always the bottom-most match. ---

case_parse "$(printf '%s\n' \
  '  the agent pasted its own footer: ▓▓▓▓▓▓▓▓ 99% 1M' \
  '  ...six or more rows of scrollback between the decoy and the footer...' \
  '  more content' '  more content' '  more content' '  more content' '  more content' \
  "$(modern_footer '▓▓░░░░░░' 21)")" 0 "ok 21" \
  "a bar+percent decoy in scrollback loses to the real footer below it"

# --- Decoys that carry no context percent stay unavailable. ---

case_parse "$(printf '%s\n' '  Claude Opus 5 (1M context)' '  ⏵⏵ bypass permissions on')" \
  64 "" "'(1M context)' with no percent -> unavailable"

case_parse "" 64 "" "empty input -> unavailable"

# A percent in the footer region that belongs to something else (a usage line) must not be
# read as context: only a labelled context percent or a bar-anchored percent counts.
case_parse "$(printf '%s\n' '  usage: 5h 6% · weekly 51%' '  ⏵⏵ bypass permissions on')" \
  64 "" "a bare percent with no label and no bar -> unavailable, not a context read"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
