#!/usr/bin/env bash
# barn.test.sh - hermetic, launch-free tests for bin/barn.sh target-mode resolution and
# the .mossy/ gitignore escape (frontier #8, slice 1). No claude, no tmux panes, no chain:
# we SOURCE barn.sh under its BASH_SOURCE guard (so main() never runs) and call the inner
# seams directly, the same way the #18.2 collision proof did. Every git operation runs in a
# throwaway repo under a temp dir that is torn down on exit.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
barn="$here/barn.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/barn-test-XXXXXX")"
hb_sess="" # the heartbeat-window cases stand up one throwaway tmux session; reaped on exit
trap '[ -n "$hb_sess" ] && tmux kill-session -t "$hb_sess" 2>/dev/null; rm -rf "$tmp"' EXIT

# barn.sh requires an executable claude at LOAD time (it resolves MOSSY_CLAUDE/PATH and
# aborts if none). We never launch it - point it at a stub so sourcing succeeds without a
# real binary, keeping this test self-contained.
stub="$tmp/claude-stub"
printf '#!/bin/sh\nexit 0\n' >"$stub"
chmod +x "$stub"
export MOSSY_CLAUDE="$stub"

# Source barn.sh: the `[ "${BASH_SOURCE[0]}" = "${0}" ]` guard means main() does NOT run.
# shellcheck source=/dev/null
. "$barn"
set +eo pipefail # relax the sourced strict mode for the harness assertions themselves

pass=0
fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
chk_eq() { if [ "$2" = "$3" ]; then ok "$1 (got '$2')"; else no "$1 (got '$2' want '$3')"; fi; }

# new_scratch_repo <name> - fresh git repo under tmp; echoes its absolute (physical) path.
new_scratch_repo() {
  local d="$tmp/$1"
  mkdir -p "$d"
  git -C "$d" init -q >/dev/null 2>&1
  (cd "$d" && pwd) # physical path - matches resolve_target's `cd && pwd`
}
# count exact ".mossy/" lines in a file (0 if the file is absent).
count_mossy() { if [ -f "$1" ]; then grep -cxF '.mossy/' "$1"; else echo 0; fi; }

# plan_cwd <plan-text> <role> - the "-c <cwd>" a --plan line prints for a role.
# A plan line is "  <role>   -c <cwd>", so awk's $3 is the cwd (test paths have no spaces).
plan_cwd() { awk -v r="$2" '$1==r{print $3}' <<<"$1"; }
# plan_env <plan-text> <KEY> - the value of KEY= on the "  env  KEY=<val>" line. Anchored to
# the env line ($1=="env") so it never picks up the heartbeat command's own KEY='...' echo.
plan_env() { awk -v k="$2" '$1=="env"{for(i=1;i<=NF;i++) if($i ~ "^" k "="){sub("^" k "=","",$i); print $i; exit}}' <<<"$1"; }

# ============================================================================
# Case A - target-mode resolution (resolve_target + cmd_resolve)
# ============================================================================
scratchA="$(new_scratch_repo repoA)"

resolved="$(resolve_target "$scratchA")"
IFS=$'\t' read -r rt rs <<<"$resolved"
chk_eq "resolve_target TARGET = absolute scratch path" "$rt" "$scratchA"
chk_eq "resolve_target STATE_DIR = <scratch>/.mossy" "$rs" "$scratchA/.mossy"
case "$rt" in /*) ok "TARGET is absolute" ;; *) no "TARGET is absolute (got '$rt')" ;; esac
case "$rs" in /*) ok "STATE_DIR is absolute" ;; *) no "STATE_DIR is absolute (got '$rs')" ;; esac

out="$(cmd_resolve "$scratchA")"
has_line() { printf '%s\n' "$out" | grep -qF "$1"; }
if has_line "= ${scratchA}"; then ok "cmd_resolve surfaces TARGET"; else no "cmd_resolve surfaces TARGET"; fi
if has_line "= ${scratchA}/.mossy"; then ok "cmd_resolve surfaces STATE_DIR"; else no "cmd_resolve surfaces STATE_DIR"; fi
if has_line "= ${scratchA}/.mossy/.barn-panes"; then ok "cmd_resolve surfaces .barn-panes path"; else no "cmd_resolve surfaces .barn-panes path"; fi

# Dogfood default (no arg): TARGET and STATE_DIR are both the repo root.
expected_repo="$(cd "$here/.." && pwd)"
resolved="$(resolve_target)"
IFS=$'\t' read -r rt rs <<<"$resolved"
chk_eq "resolve_target (no arg) TARGET = repo root" "$rt" "$expected_repo"
chk_eq "resolve_target (no arg) STATE_DIR = repo root" "$rs" "$expected_repo"

# A non-existent target is rejected (nonzero), never silently resolved.
if resolve_target "$tmp/nope-does-not-exist" >/dev/null 2>&1; then
  no "resolve_target on a missing dir returns nonzero"
else
  ok "resolve_target on a missing dir returns nonzero"
fi

# ============================================================================
# Case B - the .mossy/ exclude-write: basic effect + idempotency
# ============================================================================
# The seed's `check-ignore .mossy` guard - and a `.mossy/` (dir-only) ignore rule - only
# bite when .mossy exists as a DIRECTORY. cmd_up guarantees that: it `mkdir -p`s the state
# dir (<target>/.mossy) BEFORE seeding. Mirror that here so the test matches production.
scratchB="$(new_scratch_repo repoB)"
mkdir -p "$scratchB/.mossy"
excB="$scratchB/.git/info/exclude"

if git -C "$scratchB" check-ignore -q .mossy; then no "B pre: .mossy not yet ignored"; else ok "B pre: .mossy not yet ignored"; fi

seed_target_exclude "$scratchB"
git -C "$scratchB" check-ignore -q .mossy
chk_eq "B (a): .mossy is ignored after seeding" "$?" "0"
chk_eq "B: exactly one '.mossy/' line in info/exclude" "$(count_mossy "$excB")" "1"

seed_target_exclude "$scratchB"
chk_eq "B (b): idempotent - second seed appends no duplicate" "$(count_mossy "$excB")" "1"

# ============================================================================
# Case C - skip case 1: the target's OWN .gitignore already covers .mossy
# ============================================================================
scratchC="$(new_scratch_repo repoC)"
mkdir -p "$scratchC/.mossy"
excC="$scratchC/.git/info/exclude"
printf '.mossy/\n' >"$scratchC/.gitignore"

git -C "$scratchC" check-ignore -q .mossy
chk_eq "C pre: .mossy already ignored via .gitignore" "$?" "0"

seed_target_exclude "$scratchC"
chk_eq "C (c1): .gitignore-covered repo gets NO info/exclude append" "$(count_mossy "$excC")" "0"

# ============================================================================
# Case D - skip case 2: info/exclude already carries '.mossy/'
# ============================================================================
scratchD="$(new_scratch_repo repoD)"
mkdir -p "$scratchD/.mossy"
excD="$scratchD/.git/info/exclude"
printf '.mossy/\n' >>"$excD" # simulate a prior seed

seed_target_exclude "$scratchD"
chk_eq "D (c2): pre-seeded info/exclude gets no second line" "$(count_mossy "$excD")" "1"

# ============================================================================
# Case E - documented skip: a non-git directory is a clean no-op
# ============================================================================
plain="$tmp/plain-not-git"
mkdir -p "$plain"
seed_target_exclude "$plain"
chk_eq "E: seed on a non-git dir returns 0 (no-op)" "$?" "0"
if [ -d "$plain/.git" ]; then no "E: non-git dir untouched (no .git created)"; else ok "E: non-git dir untouched (no .git created)"; fi

# ============================================================================
# Case F - target-mode `up --plan`: path + env assertions, all absolute (no spawn)
# ============================================================================
# cmd_up --plan returns before any mkdir/tmux/claude, so it is launch-free and leaves the
# scratch repo untouched. Captured in $() so its internal `exit` (on bad input) can never
# kill the harness.
scratchF="$(new_scratch_repo repoF)"
planF="$(cmd_up --plan "$scratchF")"

chk_eq "F: MOSSY_STATE_DIR = <scratch>/.mossy (absolute)" "$(plan_env "$planF" MOSSY_STATE_DIR)" "$scratchF/.mossy"
chk_eq "F: MOSSY_REPO_DIR  = repo root (absolute)" "$(plan_env "$planF" MOSSY_REPO_DIR)" "$expected_repo"
if grep -qF "${scratchF}/.mossy/.barn-panes" <<<"$planF"; then ok "F: panes file = <scratch>/.mossy/.barn-panes"; else no "F: panes file = <scratch>/.mossy/.barn-panes"; fi
# target-mode layout: all three panes run IN the target (pane_cwds else-branch).
chk_eq "F: bitzer  cwd = target" "$(plan_cwd "$planF" bitzer)" "$scratchF"
chk_eq "F: shaun   cwd = target" "$(plan_cwd "$planF" shaun)" "$scratchF"
chk_eq "F: shirley cwd = target" "$(plan_cwd "$planF" shirley)" "$scratchF"
case "$(plan_env "$planF" MOSSY_STATE_DIR)" in /*) ok "F: STATE_DIR is absolute" ;; *) no "F: STATE_DIR is absolute" ;; esac

# ============================================================================
# Case G - dogfood `up --plan` (no target) CONTRAST: STATE_DIR is the repo root, NOT .mossy
# ============================================================================
planG="$(cmd_up --plan)"
chk_eq "G: dogfood MOSSY_STATE_DIR = repo root" "$(plan_env "$planG" MOSSY_STATE_DIR)" "$expected_repo"
if grep -qF "MOSSY_STATE_DIR=${expected_repo}/.mossy" <<<"$planG"; then no "G: dogfood STATE_DIR is NOT a .mossy subdir"; else ok "G: dogfood STATE_DIR is NOT a .mossy subdir"; fi
# dogfood layout: bitzer+shaun in the repo root, shirley in SHIRLEY_DIR (default <repo>/timmy).
chk_eq "G: dogfood bitzer  cwd = repo root" "$(plan_cwd "$planG" bitzer)" "$expected_repo"
chk_eq "G: dogfood shaun   cwd = repo root" "$(plan_cwd "$planG" shaun)" "$expected_repo"
chk_eq "G: dogfood shirley cwd = <repo>/timmy" "$(plan_cwd "$planG" shirley)" "$expected_repo/timmy"

# ============================================================================
# Case I - per-role pre-boot injection (#24): MOSSY_INJECT_<ROLE> appends to the global list,
# global-THEN-per-role, surfaced per pane in `up --plan`. Env source only (the per-role flag is
# a deferred follow-up). All launch-free: dogfood `cmd_up --plan` returns before any tmux/claude.
# Inline `VAR=val cmd_up` scopes the env to that one call; we `unset` between cases so none leak.
# ============================================================================
# plan_injects <plan-text> <role> - the ordered inject payloads a plan prints for one pane
# ('  inject  <role>  <- X' -> X), one per line. Splits on '<- ' so payloads may contain spaces.
plan_injects() { awk -v r="$2" '$1=="inject" && $2==r {sub(/^[^<]*<- /,""); print}' <<<"$1"; }

# (a) GLOBAL-ONLY: every pane gets exactly the global list, no per-role - byte-stable with the
# #18.3 inject-line format (the no-regression anchor). Assert the exact bytes AND the count, so
# a stray per-role line could not slip in unnoticed.
unset MOSSY_INJECT MOSSY_INJECT_BITZER MOSSY_INJECT_SHAUN MOSSY_INJECT_SHIRLEY
planIa="$(MOSSY_INJECT='/model default' cmd_up --plan)"
chk_eq "I(a): global-only bitzer  = global list" "$(plan_injects "$planIa" bitzer)" "/model default"
chk_eq "I(a): global-only shaun   = global list" "$(plan_injects "$planIa" shaun)" "/model default"
chk_eq "I(a): global-only shirley = global list" "$(plan_injects "$planIa" shirley)" "/model default"
byte_ok=1
for L in \
  '  inject   bitzer  <- /model default' \
  '  inject   shaun   <- /model default' \
  '  inject   shirley <- /model default'; do
  grep -qxF "$L" <<<"$planIa" || byte_ok=0
done
chk_eq "I(a): global-only inject section byte-stable (#18.3 format)" "$byte_ok" "1"
chk_eq "I(a): global-only has exactly 3 inject lines (no per-role extras)" "$(grep -c '^  inject ' <<<"$planIa")" "3"

# (b) PER-ROLE-ONLY (global unset): only the named role gets a line; the others get nothing.
unset MOSSY_INJECT MOSSY_INJECT_BITZER MOSSY_INJECT_SHAUN MOSSY_INJECT_SHIRLEY
planIb="$(MOSSY_INJECT_SHIRLEY='/model sonnet' cmd_up --plan)"
chk_eq "I(b): per-role-only shirley = the per-role line" "$(plan_injects "$planIb" shirley)" "/model sonnet"
chk_eq "I(b): per-role-only bitzer  = (no lines)" "$(plan_injects "$planIb" bitzer)" ""
chk_eq "I(b): per-role-only shaun   = (no lines)" "$(plan_injects "$planIb" shaun)" ""
chk_eq "I(b): per-role-only -> exactly 1 inject line" "$(grep -c '^  inject ' <<<"$planIb")" "1"

# (c) GLOBAL + PER-ROLE: the named pane gets global FIRST, then its per-role line appended; the
# other panes get the global list only. Pins the deterministic global-before-per-role order.
unset MOSSY_INJECT MOSSY_INJECT_BITZER MOSSY_INJECT_SHAUN MOSSY_INJECT_SHIRLEY
planIc="$(MOSSY_INJECT='/model default' MOSSY_INJECT_SHIRLEY='/model sonnet' cmd_up --plan)"
chk_eq "I(c): shirley = global THEN per-role (ordered)" "$(plan_injects "$planIc" shirley)" "$(printf '/model default\n/model sonnet')"
chk_eq "I(c): bitzer  = global only" "$(plan_injects "$planIc" bitzer)" "/model default"
chk_eq "I(c): shaun   = global only" "$(plan_injects "$planIc" shaun)" "/model default"

# (d) ABSENT or EMPTY per-role source is a clean no-op: byte-identical to global-only.
unset MOSSY_INJECT MOSSY_INJECT_BITZER MOSSY_INJECT_SHAUN MOSSY_INJECT_SHIRLEY
planId_absent="$(MOSSY_INJECT='/model default' cmd_up --plan)"
planId_empty="$(MOSSY_INJECT='/model default' MOSSY_INJECT_SHIRLEY='' cmd_up --plan)"
chk_eq "I(d): empty MOSSY_INJECT_SHIRLEY == absent (no-op)" \
  "$(grep '^  inject ' <<<"$planId_empty")" "$(grep '^  inject ' <<<"$planId_absent")"
chk_eq "I(d): empty per-role shirley still = global only" "$(plan_injects "$planId_empty" shirley)" "/model default"

# (e) ALL sources absent -> the existing '(none)' line, unchanged.
unset MOSSY_INJECT MOSSY_INJECT_BITZER MOSSY_INJECT_SHAUN MOSSY_INJECT_SHIRLEY
planIe="$(cmd_up --plan)"
if grep -qxF '  inject   (none)' <<<"$planIe"; then ok "I(e): all sources absent -> 'inject (none)'"; else no "I(e): all sources absent -> 'inject (none)'"; fi

# --- #24 slice 2: the per-role FLAG source (--inject-<role>) and full precedence ---
# (f) global --inject still fans out to ALL THREE panes (parallel to the global env): no
# per-role leakage, byte-stable with the global behaviour.
unset MOSSY_INJECT MOSSY_INJECT_BITZER MOSSY_INJECT_SHAUN MOSSY_INJECT_SHIRLEY
planIf="$(cmd_up --plan --inject '/fast on')"
chk_eq "I(f): global --inject -> bitzer"  "$(plan_injects "$planIf" bitzer)"  "/fast on"
chk_eq "I(f): global --inject -> shaun"   "$(plan_injects "$planIf" shaun)"   "/fast on"
chk_eq "I(f): global --inject -> shirley" "$(plan_injects "$planIf" shirley)" "/fast on"

# (g) per-role FLAG only: only the named role gets it; others stay empty.
planIg="$(cmd_up --plan --inject-shirley '/fast on')"
chk_eq "I(g): per-role flag only -> shirley" "$(plan_injects "$planIg" shirley)" "/fast on"
chk_eq "I(g): per-role flag only -> bitzer none" "$(plan_injects "$planIg" bitzer)" ""

# (h) per-role env THEN per-role flag (flag appended after the role's env).
planIh="$(MOSSY_INJECT_SHIRLEY='/model sonnet' cmd_up --plan --inject-shirley '/fast on')"
chk_eq "I(h): shirley = per-role env THEN per-role flag" "$(plan_injects "$planIh" shirley)" "$(printf '/model sonnet\n/fast on')"

# (i) the FULL documented precedence, all four steps in order:
#     [global env, global --inject] THEN [per-role env, --inject-<role>].
planIi="$(MOSSY_INJECT='/model default' MOSSY_INJECT_SHIRLEY='/model sonnet' \
  cmd_up --plan --inject '/fast off' --inject-shirley '/fast on')"
chk_eq "I(i): shirley full precedence [g-env, g-flag, r-env, r-flag]" \
  "$(plan_injects "$planIi" shirley)" "$(printf '/model default\n/fast off\n/model sonnet\n/fast on')"
chk_eq "I(i): bitzer = global env+flag only (no per-role)" \
  "$(plan_injects "$planIi" bitzer)" "$(printf '/model default\n/fast off')"

# (j) --inject-<role> is repeatable and appends in order.
planIj="$(cmd_up --plan --inject-shirley '/a' --inject-shirley '/b')"
chk_eq "I(j): repeatable per-role flag appends in order" "$(plan_injects "$planIj" shirley)" "$(printf '/a\n/b')"

# ============================================================================
# Case J - relaunch wiring (#24 slice 2): `relaunch --plan <role>` resolves the SAME
# global+per-role list cmd_up would give that pane, via the shared resolve_inject_for. Dogfood
# (no target) so it is launch-free - the --plan block returns before any panes file is read.
# ============================================================================
unset MOSSY_INJECT MOSSY_INJECT_BITZER MOSSY_INJECT_SHAUN MOSSY_INJECT_SHIRLEY
# (a) per-role ENV on relaunch: global THEN the role's per-role env.
planJa="$(MOSSY_INJECT='/model default' MOSSY_INJECT_SHIRLEY='/model sonnet' cmd_relaunch --plan shirley)"
chk_eq "J(a): relaunch shirley = global THEN per-role env" "$(plan_injects "$planJa" shirley)" "$(printf '/model default\n/model sonnet')"
# (b) another role's per-role source does NOT leak into this relaunch.
planJb="$(MOSSY_INJECT_BITZER='/model opus' cmd_relaunch --plan shirley)"
chk_eq "J(b): relaunch shirley ignores bitzer's per-role source" "$(plan_injects "$planJb" shirley)" ""
# (c) per-role FLAG on relaunch, appended after the role's env.
planJc="$(MOSSY_INJECT_SHIRLEY='/model sonnet' cmd_relaunch --plan --inject-shirley '/fast on' shirley)"
chk_eq "J(c): relaunch shirley = per-role env THEN per-role flag" "$(plan_injects "$planJc" shirley)" "$(printf '/model sonnet\n/fast on')"
# (d) a different role relaunches with ITS own global+per-role.
planJd="$(MOSSY_INJECT='/model default' MOSSY_INJECT_BITZER='/model opus' cmd_relaunch --plan bitzer)"
chk_eq "J(d): relaunch bitzer = global THEN per-role env" "$(plan_injects "$planJd" bitzer)" "$(printf '/model default\n/model opus')"

# ============================================================================
# Case H - heartbeat-window collision-safety (#21): resolve_hb_window over a REAL throwaway
# session. No claude: windows are plain `sleep` placeholders, torn down with the session.
# ============================================================================
hb_sess="barn_hb_test_$$"
tmux new-session -d -s "$hb_sess" -x 80 -y 24 'sleep 600' 2>/dev/null
hb_count() { tmux list-windows -t "$hb_sess" -F '#{window_name}' 2>/dev/null | grep -cxF -- "$1"; }
mkwin() { tmux new-window -d -t "$hb_sess" -n "$1" 'sleep 600' 2>/dev/null; }

# (a) HB name FREE -> created as-is (primary base reused, no orphan).
name="$(resolve_hb_window "$hb_sess" hbfree 0)"
chk_eq "H(a): free HB name returned as-is" "$name" "hbfree"
mkwin "$name"
chk_eq "H(a): HB window is uniquely named" "$(hb_count hbfree)" "1"

# (b) base REUSED + ORPHAN present -> orphan killed, new HB unique.
mkwin hborph
chk_eq "H(b) pre: orphan present" "$(hb_count hborph)" "1"
name="$(resolve_hb_window "$hb_sess" hborph 0)"
chk_eq "H(b): returns the base name" "$name" "hborph"
chk_eq "H(b): orphan was KILLED (none left before re-create)" "$(hb_count hborph)" "0"
mkwin "$name"
chk_eq "H(b): new HB uniquely named" "$(hb_count hborph)" "1"

# (c) primary ADVANCED + an INNOCENT window on the derived HB name -> innocent SURVIVES, HB
# lands on a free unique name.
mkwin hbinno
chk_eq "H(c) pre: innocent present" "$(hb_count hbinno)" "1"
name="$(resolve_hb_window "$hb_sess" hbinno 1)"
chk_eq "H(c): advanced to a free unique name" "$name" "hbinno-2"
chk_eq "H(c): innocent SURVIVED (not destroyed)" "$(hb_count hbinno)" "1"
mkwin "$name"
chk_eq "H(c): HB landed uniquely on the free name" "$(hb_count hbinno-2)" "1"

# (d) unusable session (vanished) -> nonzero on the advanced path, mirroring the primary block.
if resolve_hb_window "no_such_session_$$" hbx 1 >/dev/null 2>&1; then
  no "H(d): unusable session -> nonzero (advanced path)"
else
  ok "H(d): unusable session -> nonzero (advanced path)"
fi

tmux kill-session -t "$hb_sess" 2>/dev/null
hb_sess=""

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
