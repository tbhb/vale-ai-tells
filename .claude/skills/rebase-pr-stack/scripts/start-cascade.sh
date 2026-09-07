#!/usr/bin/env bash
# start-cascade — record where every branch in the stack stood, then run
# the cascading rebase.
#
# The recording is why this exists rather than a bare `gh stack rebase`.
# A cascade that ends without complaint has proved that every commit
# applied and nothing else. It has not proved the commits still say what
# they said, and a resolution that drops a hunk leaves a commit whose
# message describes a change it no longer makes. range-diff surfaces
# that, and range-diff needs each branch's pre-rebase tip, which stops
# existing the moment the branch moves.
#
# `gh stack sync` is the command this deliberately is not. Sync rebases
# and force-pushes in one operation, putting every branch on the remote
# before anything has read what the replay did. Splitting the two is
# what leaves room for verify-cascade.sh in between.
#
# Usage: start-cascade.sh <number|branch> [--no-trunk]
# Exit:  0 the cascade finished, 1 it stopped on a conflict, 2 it cannot
#        start.
set -euo pipefail

# --- environment hardening -------------------------------------------
export LC_ALL=C
export GH_PAGER=cat
export GH_PROMPT_DISABLED=1
export PYTHONUTF8=1
unset CDPATH GH_REPO GH_HOST GREP_OPTIONS
IFS=$' \t\n'

root=$(git rev-parse --show-toplevel)
cd "$root"
git_dir=$(git rev-parse --absolute-git-dir)
here=${BASH_SOURCE%/*}
readonly STATE="$git_dir/stack-rebase-state"

refuse() {
  printf 'start-cascade: %s\n' "$1" >&2
  exit 2
}

step() { printf '\n--- %s\n' "$1"; }

target=""
no_trunk=""
while [ $# -gt 0 ]; do
  case $1 in
  --no-trunk) no_trunk=--no-trunk ;;
  -*) refuse "unknown flag ${1}. Usage: start-cascade.sh <number|branch> [--no-trunk]" ;;
  *) target=$1 ;;
  esac
  shift
done
[ -n "$target" ] ||
  refuse "name the stack. Usage: start-cascade.sh <number|branch> [--no-trunk]"

command -v gh >/dev/null 2>&1 || refuse "gh is not installed"
gh extension list 2>/dev/null | grep -q 'gh stack' ||
  refuse "the gh stack extension is not installed"

if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
  refuse "a rebase is already in progress. Resolve and resume it with
gh stack rebase --continue, or abandon it with gh stack rebase --abort."
fi

[ -z "$(git status --porcelain=v1)" ] ||
  refuse "the working tree is dirty. The cascade checks out every branch in turn.
Park the work first:  git commit -am wip --no-verify"

# The extension is what moves the branches, and it acts only on a stack
# it tracks. Checking before the recording keeps a half-written state
# file from outliving a run that never started.
gh stack view --short >/dev/null 2>&1 ||
  refuse "gh stack has no stack tracked for the current branch. Adopt one first;
the preflight prints the gh stack init command with the branches filled in."

# --- resolve the chain -----------------------------------------------

case $target in
*[!0-9]*) number=$(gh pr list --head "$target" --state open --json number --jq '.[0].number' 2>/dev/null || true) ;;
*) number=$target ;;
esac
[ -n "$number" ] || refuse "no open pull request resolved from ${target}."

chain=$(bash "$here/stack-chain.sh" "$number")
case $chain in
ERR*) refuse "could not derive the chain: ${chain}" ;;
esac

# --- record ----------------------------------------------------------
#
# Position, branch, the branch below it, and where it stands right now.
# The trunk goes in as position 0, because the bottom member's replay is
# measured against it the same way every other member's is measured
# against the one below.

step "recording the stack"
trunk=$(printf '%s\n' "$chain" | head -1 | cut -f4)

{
  printf 'started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'was_on=%s\n' "$(git rev-parse --abbrev-ref HEAD)"
  printf 'trunk=%s\n' "$trunk"
  trunk_sha=$(git rev-parse --verify --quiet "refs/remotes/origin/$trunk" ||
    git rev-parse --verify --quiet "refs/heads/$trunk" || true)
  printf 'member\t0\t%s\t\t%s\n' "$trunk" "${trunk_sha:-}"
  printf '%s\n' "$chain" | while IFS=$'\t' read -r pos pr head base title; do
    [ -n "$head" ] || continue
    sha=$(git rev-parse --verify --quiet "refs/heads/$head" || true)
    printf 'member\t%s\t%s\t%s\t%s\n' "$pos" "$head" "$base" "${sha:-}"
  done
} >"$STATE"

awk -F'\t' '$1 == "member" {
  printf "  %s %-8s %s\n", ($2 == 0 ? "trunk" : "  " $2 "  "), substr($5, 1, 7), $3
}' "$STATE"
printf '\nrecorded in %s\n' "${STATE#"$root"/}"

missing=$(awk -F'\t' '$1 == "member" && $2 != 0 && $5 == "" { print "  " $3 }' "$STATE")
if [ -n "$missing" ]; then
  printf '\nNo local branch for:\n%s\n' "$missing"
  printf '\nThe cascade cannot move a branch this machine does not have, and\n'
  printf 'nothing will verify one either. Fetch them first, or run this against\n'
  printf 'the part of the stack that is here.\n'
fi

# --- cascade ---------------------------------------------------------

step "cascading"
printf 'gh stack rebase %s\n\n' "$no_trunk"
status=0
# shellcheck disable=SC2086  # no_trunk is one optional flag, deliberately split
gh stack rebase $no_trunk || status=$?

if [ "$status" != 0 ]; then
  if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
    printf '\nThe cascade stopped on a conflict and left a rebase in progress.\n'
    printf 'Resolve it through the resolve-rebase-conflicts skill, stage each\n'
    printf 'path, then resume:\n\n  gh stack rebase --continue\n\n'
    printf 'Abandoning restores every branch to the tips recorded above:\n\n'
    printf '  gh stack rebase --abort\n'
    exit 1
  fi
  printf '\ngh stack rebase exited %s and left no rebase in progress. The\n' "$status"
  printf 'extension restores every branch when it cannot finish, so the stack is\n'
  printf 'most likely where it started. Read the message above.\n'
  exit 1
fi

step "cascade finished"
printf 'Nothing is pushed. Read what the replay did before anything reaches the\n'
printf 'remote:\n\n'
printf '  bash .claude/skills/rebase-pr-stack/scripts/verify-cascade.sh\n'
