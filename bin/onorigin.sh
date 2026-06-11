#!/usr/bin/env bash
#
# onorigin.sh - prove a commit is on the LIVE origin before an issue is closed (Issue #12).
# Converts the close-vs-push alignment rule that today lives only as prose in prompts/shaun.md
# (steps 163-170) into an enforced vanilla guard, so a safety invariant no longer rests on
# the driver's discipline alone.
#
# The invariant: shaun can close issues but cannot push (bitzer is the sole pusher). A close
# comment cites a proving commit; if that <sha> lives only on this machine, the close tells the
# Farmer "done, see <sha>" while origin does not yet hold it - the public record diverges from
# the upstream proven state. So a close MUST be preconditioned on "<sha> is on origin".
#
# onorigin.sh <sha> [<branch>] - exit 0 IFF <sha> is an ancestor of the FRESHLY fetched live
# remote tip of <branch> (FETCH_HEAD), nonzero with a clear message otherwise. Default branch
# is the current branch. It fetches origin/<branch> right now and checks against FETCH_HEAD -
# never origin/<branch>, which can be a stale cache when you have not fetched. This is exactly
# the proven check from the prompt: `git fetch -q origin "$b"` then
# `git merge-base --is-ancestor <sha> FETCH_HEAD`.
#
# Exit codes:
#   0   on origin      - <sha> is an ancestor of the live remote tip; safe to close.
#   10  not yet        - the check RAN and <sha> is not (yet) on origin; DEFER the close.
#                        Also covers an unknown/unreachable <sha> (the prompt folds "unknown
#                        sha" into "not yet there").
#   64  usage error    - bad/missing arguments.
#   65  environment    - the check could NOT run (not a git repo, no origin, fetch failed).
#                        A close must DEFER on this too: an un-runnable check is never a proof.
#
# tva
set -uo pipefail

readonly EXIT_ONORIGIN=0
readonly EXIT_NOTYET=10
readonly EXIT_USAGE=64
readonly EXIT_ENV=65

die() { printf 'onorigin: %s\n' "$1" >&2; exit "${EXIT_USAGE}"; }

usage() {
  cat <<'EOF'
Usage:
  onorigin.sh <sha> [<branch>]

Prove <sha> is on the LIVE origin before closing an issue that cites it. Fetches origin for
<branch> (default: the current branch) and checks <sha> against the freshly fetched FETCH_HEAD.

Exit codes:
  0   on origin    - <sha> is an ancestor of the live remote tip (safe to close)
  10  not yet      - check ran; <sha> is not (yet) on origin, or is unknown (DEFER the close)
  64  usage error  - bad/missing arguments
  65  environment  - check could not run: not a git repo, no origin, or fetch failed (DEFER)
EOF
}

# env_die <msg> - an environment failure (check could not run), distinct from a clean "not yet"
# so a caller can tell "defer because un-runnable" from "defer because genuinely not there".
env_die() { printf 'onorigin: %s\n' "$1" >&2; exit "${EXIT_ENV}"; }

# on_origin <sha> <branch> - the seam the test drives. Fetch origin/<branch> into FETCH_HEAD,
# then ask whether <sha> is an ancestor of it. Returns:
#   0  ancestor (on origin)        10  ran but not an ancestor / unknown sha
#   65 could not fetch (env error)
# Prints a one-line human verdict to stdout; diagnostics go to stderr.
on_origin() {
  local sha="$1" branch="$2"
  if ! git fetch -q origin "${branch}" 2>/dev/null; then
    printf 'onorigin: could not fetch origin %s (no origin, or branch not on remote)\n' "${branch}" >&2
    return "${EXIT_ENV}"
  fi
  git merge-base --is-ancestor "${sha}" FETCH_HEAD 2>/dev/null
  case "$?" in
    0)
      printf 'on origin: %s is on origin/%s\n' "${sha}" "${branch}"
      return "${EXIT_ONORIGIN}"
      ;;
    1)
      printf 'not yet: %s is not on origin/%s\n' "${sha}" "${branch}"
      return "${EXIT_NOTYET}"
      ;;
    *)
      # git could not evaluate the merge-base: an unknown/invalid sha, which the prompt folds
      # into "not yet there" - it is provably NOT on the fetched tip.
      printf 'not yet: %s is unknown or unreachable from origin/%s\n' "${sha}" "${branch}"
      return "${EXIT_NOTYET}"
      ;;
  esac
}

main() {
  local sha="" branch=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help) usage; return 0 ;;
      -*) die "unknown argument: $1" ;;
      *)
        if [ -z "${sha}" ]; then sha="$1"
        elif [ -z "${branch}" ]; then branch="$1"
        else die "too many arguments (expected <sha> [<branch>])"
        fi
        ;;
    esac
    shift
  done

  [ -n "${sha}" ] || die "missing <sha> (usage: onorigin.sh <sha> [<branch>])"
  command -v git >/dev/null 2>&1 || env_die "git not found"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || env_die "not inside a git work tree"

  # Default branch: the current branch. A detached HEAD has no branch to fetch by name, so a
  # branch must be given explicitly in that case.
  if [ -z "${branch}" ]; then
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [ "${branch}" != "HEAD" ] && [ -n "${branch}" ] || env_die "detached HEAD - pass <branch> explicitly"
  fi

  local out rc
  out="$(on_origin "${sha}" "${branch}")"
  rc=$?
  printf '%s\n' "${out}"
  return "${rc}"
}

# Run main only when executed, not when sourced - so the test can source this file (under the
# guard, main never runs) and drive on_origin directly. The same seam barn.sh/stuck-check.sh use.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
