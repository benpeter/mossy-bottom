#!/usr/bin/env bash
# timmy test harness - vanilla, no third-party deps.
# Spins up REAL tmux panes and classifies them through timmy's public CLI,
# so we exercise capture-pane and the double-snapshot core end-to-end.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
timmy="$here/../bin/timmy"

# Fast snapshots so the suite stays quick. timmy still takes two real captures.
export TIMMY_INTERVAL="${TIMMY_INTERVAL:-0.3}"

pass=0
fail=0

ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# assert_state <session> <expected-word> <expected-exit> <label>
assert_state() {
  local sess="$1" want_word="$2" want_code="$3" label="$4"
  local out code
  out="$("$timmy" --pane "$sess" 2>/dev/null)"
  code=$?
  if [ "$out" = "$want_word" ] && [ "$code" -eq "$want_code" ]; then
    ok "$label (got '$out' exit $code)"
  else
    no "$label (got '$out' exit $code; wanted '$want_word' exit $want_code)"
  fi
}

# --- fixture: an idle pane (static content, nothing advancing) ---
idle_sess="timmy_t_idle_$$"
tmux new-session -d -s "$idle_sess" -x 80 -y 24 \
  'printf "\xe2\x9d\xaf\n"; sleep 600' 2>/dev/null
sleep 0.5  # let the pane settle before we snapshot

assert_state "$idle_sess" idle 0 "static pane classified idle"

tmux kill-session -t "$idle_sess" 2>/dev/null

# --- fixture: a busy pane (output advances between snapshots) ---
busy_sess="timmy_t_busy_$$"
tmux new-session -d -s "$busy_sess" -x 80 -y 24 \
  'while true; do date +%s%N; sleep 0.05; done' 2>/dev/null
sleep 0.5

assert_state "$busy_sess" busy 10 "advancing pane classified busy"

tmux kill-session -t "$busy_sess" 2>/dev/null

# --- fixture: a STALLED pane - identical snapshots but a spinner is present.
# Snapshot-diff alone would call this idle; the spinner cue must force busy. The
# active spinner LINE carries its live counter in parens (e2 97 8f "●", e2 80 a6
# "…", c2 b7 "·"): "● Whirring… (esc to interrupt · 1.2k tokens)".
spin_sess="timmy_t_spin_$$"
tmux new-session -d -s "$spin_sess" -x 80 -y 24 \
  'printf "\xe2\x97\x8f Whirring\xe2\x80\xa6 (esc to interrupt \xc2\xb7 1.2k tokens)\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$spin_sess" busy 10 "stalled frame with spinner classified busy"

tmux kill-session -t "$spin_sess" 2>/dev/null

# --- GAP-1a (#9): the same active spinner but with an ASCII three-dot ellipsis
# "..." instead of the … glyph. The SHAPE cue must still read busy regardless of
# how the ellipsis renders - else a working pane reads idle and gets interrupted. ---
dots_sess="timmy_t_dots_$$"
tmux new-session -d -s "$dots_sess" -x 80 -y 24 \
  'printf "\xe2\x97\x8f Whirring... (esc to interrupt)\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$dots_sess" busy 10 "GAP-1a spinner with ASCII '...' ellipsis classified busy"

tmux kill-session -t "$dots_sess" 2>/dev/null

# --- GAP-1b (#9): an active spinner led by a DIFFERENT frame glyph than "●"
# (here U+2736 "✶" = e2 9c b6) with a past-tense verb. Glyph- and verb-agnostic:
# the shape (leading glyph + verb + ellipsis + counter) must still read busy. ---
glyph_sess="timmy_t_glyph_$$"
tmux new-session -d -s "$glyph_sess" -x 80 -y 24 \
  'printf "\xe2\x9c\xb6 Cooked\xe2\x80\xa6 (3s)\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$glyph_sess" busy 10 "GAP-1b spinner with alt glyph + past-tense verb classified busy"

tmux kill-session -t "$glyph_sess" 2>/dev/null

# --- #10 NOT-REGRESSED: a REAL spinner at the very bottom, with report content scrolled
# ABOVE it. The bottom spinner must still fire (busy) even though content precedes it -
# bottom-anchoring keeps the real live spinner, it only rejects content above. (No idle
# box here, so this can sit with the other spinner fixtures, before idle_box is defined.) ---
realspin_sess="timmy_t_realspin_$$"
tmux new-session -d -s "$realspin_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba Here is a lot of report content from the last turn.\n  more content.\n  even more content.\n\xe2\x97\x8f Whirring\xe2\x80\xa6 (esc to interrupt \xc2\xb7 1.2k tokens)\n'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$realspin_sess" busy 10 "#10 real bottom spinner with content above it -> busy"

tmux kill-session -t "$realspin_sess" 2>/dev/null

# --- fixture: a selection menu (the trust gate shape, smoke-test.md section 9).
# Numbered options with a cursor plus an "Enter to confirm" affordance line.
menu_sess="timmy_t_menu_$$"
tmux new-session -d -s "$menu_sess" -x 80 -y 24 \
  'printf "\xe2\x9d\xaf 1. Yes, I trust this folder\n  2. No, exit\n Enter to confirm \xc2\xb7 Esc to cancel\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$menu_sess" waiting-input 20 "selection menu classified waiting-input"

tmux kill-session -t "$menu_sess" 2>/dev/null

# --- GAP-2 (#9) false-NEGATIVE: a REAL selection menu on a NARROW pane (width 14),
# where the "Enter to confirm" affordance WRAPS mid-phrase. The old phrase-based cue
# missed this (verified live); the structural shape - the "❯ <n>" cursor plus >=2
# numbered options, all short and left-aligned - survives the wrap. A miss here is the
# dangerous direction (a menu read as idle -> a driver types into the trust gate). ---
mnar_sess="timmy_t_mnar_$$"
tmux new-session -d -s "$mnar_sess" -x 14 -y 24 \
  'printf "\xe2\x9d\xaf 1. Yes\n  2. No\n Enter to confirm \xc2\xb7 Esc to cancel\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$mnar_sess" waiting-input 20 "GAP-2 narrow real menu (affordance wraps) classified waiting-input"

tmux kill-session -t "$mnar_sess" 2>/dev/null

# --- GAP-3 (#9) false-NEGATIVE: a REAL menu with ALTERNATE/absent affordance wording -
# no "Enter to confirm" phrase at all (a permission-style prompt). The shape (cursor +
# numbered options) must still classify waiting-input regardless of the affordance text. ---
malt_sess="timmy_t_malt_$$"
tmux new-session -d -s "$malt_sess" -x 80 -y 24 \
  'printf "\xe2\x9d\xaf 1. Allow this command\n  2. Deny\n  3. Always allow\n  Use arrow keys, then press return to choose\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$malt_sess" waiting-input 20 "GAP-3 real menu with alternate wording classified waiting-input"

tmux kill-session -t "$malt_sess" 2>/dev/null

# --- GAP-2 (#9) false-POSITIVE, the 14:17 case: a WORKING pane whose CONTENT is
# displaying the menu-detection source itself - "❯ 1." and "Enter to confirm" sit in the
# text - while an active spinner runs at the bottom. The old menu-first precedence read
# this as waiting-input (an obey-the-classifier driver would have injected a stray menu
# answer into a working session). Spinner-before-menu precedence must read it BUSY. ---
mfp_sess="timmy_t_mfp_$$"
tmux new-session -d -s "$mfp_sess" -x 80 -y 24 \
  'printf "\xe2\x8f\xba Editing has_menu: it keyed on \xe2\x9d\xaf 1. and the Enter to confirm line.\n  \xe2\x9d\xaf 1. Yes, I trust this folder\n    2. No, exit\n  Enter to confirm \xc2\xb7 Esc to cancel\n\xe2\x97\x8f Churning\xe2\x80\xa6 (esc to interrupt \xc2\xb7 2k tokens)\n"; sleep 600' 2>/dev/null
sleep 0.5

assert_state "$mfp_sess" busy 10 "GAP-2 working pane displaying menu source (14:17 case) classified busy, not menu"

tmux kill-session -t "$mfp_sess" 2>/dev/null

# A genuine Claude idle box: empty "❯" box fenced by rules, mode line ending in
# the "← for agents" suffix (smoke-test.md section 2). The two fixtures below
# differ only in whether the last assistant ("⏺") line ends in a question mark.
# Note: '%%' so the pane's printf emits a literal '%' (Context: 5%). The mode
# line carries the real "⏵⏵ ... (shift+tab to cycle) · ← for agents" shape.
idle_box='\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/timmy | Opus 4.8 | Context: 5%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle) \xc2\xb7 \xe2\x86\x90 for agents\n'

# --- fixture: idle box whose last assistant line ends in '?' -> question ---
q_sess="timmy_t_q_$$"
tmux new-session -d -s "$q_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba Want me to take question next, or harden idle first?\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$q_sess" question 30 "idle box ending in '?' classified question"

tmux kill-session -t "$q_sess" 2>/dev/null

# --- fixture: same genuine idle box, last assistant line ends in '.' -> idle.
# Proves the idle box is positively recognised and NOT misread as question. ---
ib_sess="timmy_t_ib_$$"
tmux new-session -d -s "$ib_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba All four states are wired up now.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$ib_sess" idle 0 "genuine idle box (ends in '.') classified idle"

tmux kill-session -t "$ib_sess" 2>/dev/null

# --- GAP-7 (#9): an idle pane whose CONTENT mentions a "●" bullet and a "…"
# ellipsis on one line, plus a "✻ Cooked for 5s" summary - the exact shapes that a
# finished report can contain. The OLD bare "●.*…" cue false-fired busy on such a
# line (it happened live to the operator's own instrument). The shape cue must read
# idle: none of these is an active spinner LINE (the glyphs are mid-line content, the
# summary has no immediate ellipsis or parenthesised counter). '⏺' = e2 8f ba. ---
g7_sess="timmy_t_g7_$$"
tmux new-session -d -s "$g7_sess" -x 100 -y 30 \
  "printf '\xe2\x8f\xba Report: a \xe2\x97\x8f bullet and a \xe2\x80\xa6 ellipsis share one line of content.\n  \xe2\x9c\xbb Cooked for 5s - this summary glyph is inline prose, not a live spinner.\n  All checks complete.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$g7_sess" idle 0 "GAP-7 idle report with inline ● bullet and ✻ summary classified idle, not busy"

tmux kill-session -t "$g7_sess" 2>/dev/null

# --- GAP-2 (#9) false-POSITIVE, settled variant: an IDLE pane (genuine "⏵⏵" box) whose
# CONTENT quotes a full menu - cursor line, numbered options, and an "Enter to confirm"
# line. The old menu-first precedence read this as waiting-input; the settled idle box is
# decided before the menu shape, so it must read idle. (The "❯" in the quoted menu carries
# an option number, so it is not the empty input box - box and menu stay distinct.) ---
mci_sess="timmy_t_mci_$$"
tmux new-session -d -s "$mci_sess" -x 100 -y 30 \
  "printf '\xe2\x8f\xba The menu cue keys on \xe2\x9d\xaf 1. plus an Enter to confirm line:\n  \xe2\x9d\xaf 1. Yes, I trust this folder\n    2. No, exit\n  Enter to confirm \xc2\xb7 Esc to cancel\n  Done reviewing the menu cue.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$mci_sess" idle 0 "GAP-2 idle pane quoting a full menu in content classified idle, not menu"

tmux kill-session -t "$mci_sess" 2>/dev/null

# A NARROW idle box (width 50): the mode line truncates before "← for agents"
# (verified empirically against a live session: "...(shift+tab to cycle ·"). The
# width-robust cues - the "⏵⏵" mode marker and the empty "❯" box - must still
# identify the idle box so question/idle work at narrow widths. '%%' -> '%'.
narrow_box='\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/t | Opus 4.8 | Ctx 5%%\n  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle \xc2\xb7\n'

# --- fixture: narrow idle box whose last assistant line ends in '?' -> question.
nq_sess="timmy_t_nq_$$"
tmux new-session -d -s "$nq_sess" -x 50 -y 24 \
  "printf '\xe2\x8f\xba Should I proceed with the merge?\n${narrow_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$nq_sess" question 30 "narrow idle box ending in '?' classified question"

tmux kill-session -t "$nq_sess" 2>/dev/null

# --- fixture: same narrow box, last line ends in '.' -> idle (guard). ---
ni_sess="timmy_t_ni_$$"
tmux new-session -d -s "$ni_sess" -x 50 -y 24 \
  "printf '\xe2\x8f\xba All settled now.\n${narrow_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$ni_sess" idle 0 "narrow idle box (ends in '.') classified idle"

tmux kill-session -t "$ni_sess" 2>/dev/null

# A MULTI-LINE assistant turn (reconstructed from a verbatim live capture): the
# question is an indented CONTINUATION line (no "⏺" prefix), followed by the
# "✻ ... for Ns" post-turn timer and a tip footer. The last content line of the
# message - not the last "⏺" line - is the question. '✻' = e2 9c bb.
mlq_sess="timmy_t_mlq_$$"
tmux new-session -d -s "$mlq_sess" -x 100 -y 30 \
  "printf '\xe2\x8f\xba - tmux lets you run multiple terminal sessions in one window via splits and panes.\n  - tmux sessions persist after you detach, so long-running work survives disconnects.\n\n  Which one do you want me to explain?\n\n\xe2\x9c\xbb Cooked for 5s\n  tmux focus-events off, a footer tip ending in a period.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$mlq_sess" question 30 "multi-line turn (question as continuation line) classified question"

tmux kill-session -t "$mlq_sess" 2>/dev/null

# Guard: a statement as the last content line, with ADVERSARIAL chrome - the tip
# footer below "✻" ends in '?'. The footer must not mask the real last line, and
# must not fabricate a question: this must read idle, not question.
cs_sess="timmy_t_cs_$$"
tmux new-session -d -s "$cs_sess" -x 100 -y 30 \
  "printf '\xe2\x8f\xba All four states are wired up now.\n\n\xe2\x9c\xbb Cooked for 1s\n  Tip: press ? for keyboard shortcuts?\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$cs_sess" idle 0 "statement with adversarial '?' chrome footer classified idle"

tmux kill-session -t "$cs_sess" 2>/dev/null

# A FULLY-SETTLED frame: the "✻ ... for Ns" post-turn timer has DISAPPEARED, but
# a tip/hint footer still lingers directly above the input box. The timer was the
# anchor the cut relied on; with it gone, the footer must NOT be mistaken for the
# closing content line. Here the true last line is a question, the lingering
# footer is a real-shaped hint line ("... · ..."). The footer must be stripped by
# its own signature so the question still wins. '·' = c2 b7.
ntq_sess="timmy_t_ntq_$$"
tmux new-session -d -s "$ntq_sess" -x 100 -y 30 \
  "printf '\xe2\x8f\xba Here are two tmux concepts worth knowing.\n  Which one do you want me to explain?\n\n  esc to interrupt \xc2\xb7 ctrl+t to show todos\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$ntq_sess" question 30 "settled frame, timer gone, lingering hint footer, question survives"

tmux kill-session -t "$ntq_sess" 2>/dev/null

# Same shape, adversarial: timer gone, true last line is a STATEMENT, and the
# lingering "Tip:" footer itself ends in '?'. The footer must be stripped (not
# treated as content) and must not fabricate a question: this reads idle.
nts_sess="timmy_t_nts_$$"
tmux new-session -d -s "$nts_sess" -x 100 -y 30 \
  "printf '\xe2\x8f\xba All four states are wired up now.\n\n  Tip: press ? for keyboard shortcuts?\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$nts_sess" idle 0 "settled frame, timer gone, adversarial '?' tip footer, stays idle"

tmux kill-session -t "$nts_sess" 2>/dev/null

# --- GAP-4 (#9): a NARROW pane (width 50) where the post-turn timer's trailing hint
# WRAPS, so "for Ns" is no longer at the line end. The old end-anchored timer regex
# (✻.*for [0-9]+s *$) missed the timer here and could mislocate the closing line; the
# shape-based timer chrome (glyph-led + elapsed token, not end-anchored) still stops
# the scan, so the real question survives. '✻' = e2 9c bb. ---
g4_sess="timmy_t_g4_$$"
tmux new-session -d -s "$g4_sess" -x 50 -y 24 \
  "printf '\xe2\x8f\xba Here is the tradeoff you asked about.\n  Which option should I take?\n\xe2\x9c\xbb Sauteed for 5s (esc to interrupt \xc2\xb7 ctrl+t to show todos)\n${narrow_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$g4_sess" question 30 "GAP-4 narrow pane, timer trailing hint wraps, question survives"

tmux kill-session -t "$g4_sess" 2>/dev/null

# --- GAP-5 (#9): a post-turn timer with a CHANGED glyph and wording - "✦ Cooked (5s)"
# instead of "✻ Cooked for 5s". The old timer regex keyed on "✻" and "for Ns" and would
# miss this, then mistake the timer line for the closing content and degrade to idle. The
# glyph-agnostic shape (any non-⏺ glyph + elapsed token) still strips it. '✦' = e2 9c a6. ---
g5_sess="timmy_t_g5_$$"
tmux new-session -d -s "$g5_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba Two approaches are possible here.\n  Which approach do you prefer?\n\xe2\x9c\xa6 Cooked (5s)\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$g5_sess" question 30 "GAP-5 alt timer glyph and wording, question survives"

tmux kill-session -t "$g5_sess" 2>/dev/null

# --- GAP-6 (#9): a real idle box WITHOUT the "⏵⏵" mode marker (and no "shift+tab") -
# only the "─" rule fence and the empty "❯". Question detection used to require "⏵⏵", so
# a changed/absent marker silently degraded a real question to idle. is_idle_box now
# corroborates on any one box cue (here the rules), so the box - and the question - hold.
# '─' = e2 94 80, '❯' = e2 9d af; '%%' -> literal '%'. ---
g6_box='\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\n\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n  ~/proj | Opus 4.8 | Context: 9%%\n'
g6_sess="timmy_t_g6_$$"
tmux new-session -d -s "$g6_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba I need a decision before continuing.\n  Should I proceed with the deploy?\n${g6_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$g6_sess" question 30 "GAP-6 idle box WITHOUT the ⏵⏵ marker, question survives"

tmux kill-session -t "$g6_sess" 2>/dev/null

# --- GAP-8 (#9): a genuine CLOSING QUESTION that itself contains "·". The old timer-gone
# branch stripped ANY line containing " · " as chrome, deleting such a question and
# degrading to idle. Chrome is now matched by signature, never by "·", so the question
# survives. '·' = c2 b7. ---
g8_sess="timmy_t_g8_$$"
tmux new-session -d -s "$g8_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba A few routing options exist.\n  Use route A \xc2\xb7 route B \xc2\xb7 route C?\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$g8_sess" question 30 "GAP-8 closing question containing '·' classified question, not stripped"

tmux kill-session -t "$g8_sess" 2>/dev/null

# --- GAP-8 guard (#9), inverse: a "·"-bearing line that IS chrome (a key-hint footer)
# above a STATEMENT must still be stripped, and must not fabricate a question - stays
# idle. Proves the signature-based strip still removes real "·" chrome. ---
g8g_sess="timmy_t_g8g_$$"
tmux new-session -d -s "$g8g_sess" -x 80 -y 24 \
  "printf '\xe2\x8f\xba All checks are complete now.\n  esc to interrupt \xc2\xb7 ctrl+t to show todos\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$g8g_sess" idle 0 "GAP-8 guard: '·' key-hint chrome stripped, statement stays idle"

tmux kill-session -t "$g8g_sess" 2>/dev/null

# --- #10 SHADOW-REJECTION: a spinner-shaped line sits in CONTENT above a real IDLE box
# at the very bottom. Before bottom-anchoring the spinner fired on the content glyph and
# read busy (reproduced live); now the spinner cue reads only the bottom region, so the
# content spinner cannot shadow the real idle box. Must read idle, not busy. ---
shspin_idle_sess="timmy_t_shspin_idle_$$"
tmux new-session -d -s "$shspin_idle_sess" -x 80 -y 24 \
  "printf '\xe2\x97\x8f Churning\xe2\x80\xa6 (esc to interrupt \xc2\xb7 1.2k tokens)\n  my report quotes that captured spinner line above; I am actually idle.\n  another line of the report.\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$shspin_idle_sess" idle 0 "#10 content spinner above a real idle box -> idle, not busy"

tmux kill-session -t "$shspin_idle_sess" 2>/dev/null

# --- #10 SHADOW-REJECTION: a content spinner above a real QUESTION at the bottom. The
# real bottom state (an idle box whose closing line is a question) must win. ---
shspin_q_sess="timmy_t_shspin_q_$$"
tmux new-session -d -s "$shspin_q_sess" -x 80 -y 24 \
  "printf '\xe2\x97\x8f Propagating\xe2\x80\xa6 (esc to interrupt)\n\xe2\x8f\xba Should I proceed with the merge?\n${idle_box}'; sleep 600" 2>/dev/null
sleep 0.5

assert_state "$shspin_q_sess" question 30 "#10 content spinner above a real question -> question, not busy"

tmux kill-session -t "$shspin_q_sess" 2>/dev/null

# --- fixture: --watch emits one line per state CHANGE only ---
# Drive a pane through idle -> busy -> idle and assert watch prints EXACTLY three
# lines in that order, with NO duplicate while a state is held. The pane holds
# each state ~2s; watch polls at TIMMY_INTERVAL. busy is forced by the spinner
# cue (deterministic on a static frame), idle by static plain content.
w_sess="timmy_t_watch_$$"
w_out="$(mktemp "${TMPDIR:-/tmp}/timmy-watch-XXXXXX")"
tmux new-session -d -s "$w_sess" -x 80 -y 24 \
  "printf 'IDLE-A\n'; sleep 2; printf '\xe2\x97\x8f Whirring\xe2\x80\xa6 (esc to interrupt)\n'; sleep 2; clear; printf 'IDLE-B\n'; sleep 600" 2>/dev/null
sleep 0.5  # let IDLE-A paint before watch takes its first read

"$timmy" --watch --pane "$w_sess" > "$w_out" 2>/dev/null &
w_pid=$!
sleep 6                       # span all three phases (idle, busy, idle)
kill "$w_pid" 2>/dev/null     # SIGTERM -> watch must exit cleanly, flushing output
wait "$w_pid" 2>/dev/null

w_seq="$(awk '{print $1}' "$w_out" | tr '\n' ',')"
w_n=$(awk 'END{print NR}' "$w_out")
if [ "$w_n" -eq 3 ] && [ "$w_seq" = "idle,busy,idle," ]; then
  ok "watch emits idle,busy,idle once each on change (got '$w_seq')"
else
  no "watch emits idle,busy,idle once each on change (got '$w_seq' in $w_n lines)"
fi

tmux kill-session -t "$w_sess" 2>/dev/null
rm -f "$w_out"

# --- fixture: a BLANK pane (no output at all). An empty capture is NOT an error:
# two identical empty snapshots classify idle via the snapshot-diff fallback. This
# guards the boundary between "empty" (idle) and "capture failed" (the error below). ---
blank_sess="timmy_t_blank_$$"
tmux new-session -d -s "$blank_sess" -x 80 -y 24 'sleep 600' 2>/dev/null
sleep 0.5

assert_state "$blank_sess" idle 0 "blank pane (empty capture) classified idle, not error"

tmux kill-session -t "$blank_sess" 2>/dev/null

# --- fixture: a GONE pane - capture-pane FAILS. The classify-error path: --await
# must exit EXIT_WATCH_ERR (65), not hang or spin. We target a session that was
# never created, so the first capture fails immediately. (single-shot would die 64;
# 65 is the watch/await error code, reused so the modes cannot drift.) ---
gone_sess="timmy_t_gone_$$" # intentionally never created
"$timmy" --await --pane "$gone_sess" --timeout 1 >/dev/null 2>&1
gone_code=$?
if [ "$gone_code" -eq 65 ]; then
  ok "capture failure on a gone pane exits 65 (EXIT_WATCH_ERR)"
else
  no "capture failure on a gone pane exits 65 (got exit $gone_code)"
fi

# --- fixture: --json serialises the classifier output. An idle pane must emit a
# JSON object whose state is "idle" with exit 0 - the structured-output path, not
# just the bare state word. ---
json_sess="timmy_t_json_$$"
tmux new-session -d -s "$json_sess" -x 80 -y 24 \
  'printf "\xe2\x9d\xaf\n"; sleep 600' 2>/dev/null
sleep 0.5

json_out="$("$timmy" --pane "$json_sess" --json 2>/dev/null)"
json_code=$?
if [ "$json_code" -eq 0 ] && [[ "$json_out" == '{"state":"idle",'* ]]; then
  ok "--json emits an idle state object, exit 0"
else
  no "--json idle object (got '$json_out' exit $json_code)"
fi

tmux kill-session -t "$json_sess" 2>/dev/null

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
