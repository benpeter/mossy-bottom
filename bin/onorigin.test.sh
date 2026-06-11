#!/usr/bin/env bash
# onorigin.test.sh - hermetic, network-free tests for bin/onorigin.sh (Issue #12).
# We stand up a throwaway local git repo with a LOCAL BARE "origin" (no network, no gh) and
# assert the guard's core claim: exit 0 IFF the <sha> has actually reached origin, nonzero
# (and never 0) while it lives only on this machine. We also prove the freshness property the
# rule hinges on - onorigin fetches LIVE, so it sees a commit another clone just pushed even
# though our own origin/<branch> cache is stale.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
sc="$here/onorigin.sh"

bash -n "$sc" || { echo "FAIL: onorigin.sh failed bash -n"; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/onorigin-test-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Hermetic git: a sandboxed identity and config so the suite never touches the user's git.
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git config --global init.defaultBranch main >/dev/null 2>&1 || true

pass=0
fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }

# run_on <dir> <args...> - run onorigin.sh from inside <dir> (the guard reads the cwd repo).
# Sets globals OUT (stdout) and CODE (exit status).
run_on() {
  local dir="$1"; shift
  OUT="$(cd "$dir" && "$sc" "$@" 2>/dev/null)"
  CODE=$?
}

# expect <label> <want_code> <dir> <args...> - assert the exit code.
expect() {
  local label="$1" want="$2" dir="$3"; shift 3
  run_on "$dir" "$@"
  if [ "$CODE" -eq "$want" ]; then
    ok "$label (exit $CODE)"
  else
    no "$label (got exit $CODE, wanted $want; out: '$OUT')"
  fi
}

# --- Build a local bare "origin" and a working clone, no network involved. ---
origin="$tmp/origin.git"
work="$tmp/work"
git init -q --bare "$origin"
git init -q "$work"
git -C "$work" symbolic-ref HEAD refs/heads/main   # deterministic unborn branch name
git -C "$work" remote add origin "$origin"

# First commit, pushed to origin -> it IS on origin.
printf 'one\n' >"$work/a.txt"
git -C "$work" add a.txt
git -C "$work" commit -q -m one
pushed_sha="$(git -C "$work" rev-parse HEAD)"
git -C "$work" push -q -u origin main

printf '== pushed vs local-only ==\n'
expect "pushed commit -> on origin (0)"              0  "$work" "$pushed_sha"
expect "pushed commit, explicit branch -> on origin" 0  "$work" "$pushed_sha" main

# Second commit, committed locally but NOT pushed -> only on this machine.
printf 'two\n' >>"$work/a.txt"
git -C "$work" commit -q -am two
local_sha="$(git -C "$work" rev-parse HEAD)"
expect "local-only commit -> NOT yet on origin (10)" 10 "$work" "$local_sha"

# Critical safety edge: the local-only commit must NEVER read as on-origin, even though it is
# the current HEAD and a stale origin/main ref still points at the old tip.
run_on "$work" "$local_sha"
if [ "$CODE" -ne 0 ]; then
  ok "local-only HEAD never reads as on-origin (exit $CODE != 0)"
else
  no "local-only HEAD wrongly read as on-origin (exit 0) - SAFETY VIOLATION"
fi

# Now push it; the very next check must flip to on-origin.
git -C "$work" push -q origin main
expect "after push -> on origin (0)"                 0  "$work" "$local_sha"

printf '\n== freshness: live fetch beats a stale origin/<branch> cache ==\n'
# A SECOND clone advances origin. Our 'work' repo never fetches it, so work's origin/main is
# stale - but onorigin fetches LIVE, so it must still see the newly pushed commit.
work2="$tmp/work2"
git clone -q "$origin" "$work2"
printf 'three\n' >>"$work2/a.txt"
git -C "$work2" commit -q -am three
fresh_sha="$(git -C "$work2" rev-parse HEAD)"
git -C "$work2" push -q origin main

stale="$(git -C "$work" rev-parse origin/main)"   # work's cached ref, pre-fetch
if [ "$stale" != "$fresh_sha" ]; then
  ok "precondition: work's origin/main is stale (cache != live tip)"
else
  no "precondition failed: work already had the fresh commit"
fi
expect "live-pushed commit seen via fresh fetch (0)" 0  "$work" "$fresh_sha"

printf '\n== not-on-origin and error edges ==\n'
expect "unknown sha -> not yet (10)"                 10 "$work" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

# No origin remote -> the check cannot run -> environment error (65), never a false 0.
noremote="$tmp/noremote"
git init -q "$noremote"
git -C "$noremote" symbolic-ref HEAD refs/heads/main
printf 'x\n' >"$noremote/a.txt"
git -C "$noremote" add a.txt
git -C "$noremote" commit -q -m x
nr_sha="$(git -C "$noremote" rev-parse HEAD)"
expect "no origin remote -> environment error (65)"  65 "$noremote" "$nr_sha"

# Not a git work tree -> environment error (65).
expect "non-git dir -> environment error (65)"       65 "$tmp" "$pushed_sha"

# Missing <sha> -> usage error (64).
expect "missing sha -> usage error (64)"             64 "$work"

# --help -> exit 0 (and prints usage).
run_on "$work" --help
if [ "$CODE" -eq 0 ] && printf '%s' "$OUT" | grep -q 'Usage:'; then
  ok "--help -> usage, exit 0"
else
  no "--help -> usage, exit 0 (got exit $CODE)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
