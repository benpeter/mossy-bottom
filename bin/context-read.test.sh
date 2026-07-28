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

# --- The status line keeps changing shape, so the read is anchored on POSITION, not on
# the decoration. Any number followed by % below the input box's rule is the context. ---

case_parse "$(printf '%s\n' \
  '──────────────────────────────────────────────────────────────────' \
  '  Opus 5   ~/dev/adobe   main   44% 1M' \
  '  ⏵⏵ bypass permissions on')" 0 "ok 44" \
  "a future status line, percent with no bar and no label -> read as context"

# A warning row can sit between the rule and the model row (an inherited-marker warning
# does). It carries no percent, and must not shadow the row that does.
case_parse "$(printf '%s\n' \
  '──────────────────────────────────────────────────────────────────' \
  '  ⚠ Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker · resta…' \
  "  Opus 5   ~/dev/adobe   main   ▓▓▓▓░░░░ 48% 1M" \
  '  ⏵⏵ bypass permissions on')" 0 "ok 48" \
  "a warning row above the status row does not shadow the percent"

# What the Farmer types into the input box sits ABOVE the rule, so a percent in it is never
# read as context. This is the whole reason the region is rule-anchored and not "last N
# rows": a pasted directive mentioning "51%" must not gauge the pane.
case_parse "$(printf '%s\n' \
  '──────────────────────────────────────────────────────────────────' \
  '❯ usage is 5h 6% and weekly 51%, keep going' \
  '──────────────────────────────────────────────────────────────────' \
  "  Opus 5   ~/dev/adobe   main   ▓▓░░░░░░ 19% 1M" \
  '  ⏵⏵ bypass permissions on')" 0 "ok 19" \
  "a percent typed into the input box loses to the status line below the rule"

# --- The LIVE path reads the pane TWICE and requires the two to agree. A capture taken
# while the TUI repaints returns a torn frame, and a torn frame can carry a percent that is
# not the context: resizing the window produced exactly one such read, "compact 80" against
# a pane whose footer said 10%, and a spurious compact makes the agent dump its context for
# nothing. Two agreeing frames are the evidence; disagreement is unavailable, which is the
# documented fail-safe (skip the check). Exercised with a `tmux` stub on PATH - no pane,
# no live server. ---

stub_n=0

# live_case <frame1> <frame2> <want-code> <want-out> <label>: a stub tmux that emits frame1
# on its first capture-pane and frame2 on the second.
live_case() {
  local f1="$1" f2="$2" want_code="$3" want_out="$4" label="$5" out code bindir
  stub_n=$((stub_n + 1))
  bindir="$tmp_stub/stub$stub_n"
  mkdir -p "$bindir"
  printf '%s\n' "$f1" >"$bindir/frame1"
  printf '%s\n' "$f2" >"$bindir/frame2"
  cat >"$bindir/tmux" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
n="$(cat "$d/n" 2>/dev/null || echo 0)"
n=$((n + 1))
printf '%s' "$n" >"$d/n"
if [ "$n" -le 1 ]; then cat "$d/frame1"; else cat "$d/frame2"; fi
STUB
  chmod +x "$bindir/tmux"
  out="$(PATH="$bindir:$PATH" "$cr" --pane %9 2>/dev/null)"
  code=$?
  if [ "$code" -eq "$want_code" ] && [ "$out" = "$want_out" ]; then
    ok "$label"
  else
    no "$label (exit $code want $want_code; stdout '$out' want '$want_out')"
  fi
}

tmp_stub="$(mktemp -d "${TMPDIR:-/tmp}/context-read-stub-XXXXXX")"
trap 'rm -rf "$tmp_stub"' EXIT

steady="$(modern_footer '▓░░░░░░░' 10)"
torn="$(printf '%s\n' '  a half-painted row claiming 80%' '  ⏵⏵ bypass permissions on')"

live_case "$steady" "$steady" 0 "ok 10" \
  "live: two agreeing frames -> the read stands"

live_case "$torn" "$steady" 64 "" \
  "live: a torn first frame disagreeing with the settled one -> unavailable, not compact"

live_case "$steady" "$torn" 64 "" \
  "live: a torn second frame -> unavailable, not a wrong number"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
