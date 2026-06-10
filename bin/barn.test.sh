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
trap 'rm -rf "$tmp"' EXIT

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
