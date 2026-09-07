#!/usr/bin/env bash
# push-stack — the one thing in this workflow that puts the rebased
# stack on the remote.
#
# A cascade rewrites every branch above the first one that moved, so the
# push that follows is a force push across the whole stack. That is the
# moment anything pushed to one of those branches from somewhere else is
# discarded, and it happens to several branches at once. So it runs
# behind the verification rather than beside it: this re-runs
# verify-cascade.sh and refuses on anything it flags, rather than
# trusting that someone ran it earlier and read the result.
#
# `gh stack sync` performs the push. Its force is --force-with-lease and
# its push is --atomic, which is what makes a stack-wide rewrite
# survivable: the lease refuses a branch that moved underneath this
# machine, and atomic means the remote takes all the branches or none.
# It also relinks the pull requests into a stack on GitHub afterwards.
#
# Usage: push-stack.sh
# Exit:  0 pushed, 1 refused or the push failed.
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

die() {
  printf 'push-stack: %s\n' "$1" >&2
  exit 1
}

step() { printf '\n--- %s\n' "$1"; }

command -v gh >/dev/null 2>&1 || die "gh is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated"
gh extension list 2>/dev/null | grep -q 'gh stack' ||
  die "the gh stack extension is not installed"

[ -s "$STATE" ] ||
  die "no recording at ${STATE#"$root"/}. This pushes what start-cascade.sh moved,
and without the recording nothing here knows what that was."

if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
  die "a rebase is in progress. Finish the cascade before pushing any of it."
fi

# --- gate: the verification ------------------------------------------
#
# Re-run rather than read a signature. The tree is what gets pushed, and
# a signature over a recording says nothing about the tree as it stands
# right now.

step "re-running the verification"
if bash "$here/verify-cascade.sh" >/dev/null 2>&1; then
  printf 'clean\n'
else
  die "verify-cascade.sh flagged something. Read it in full:

  bash .claude/skills/rebase-pr-stack/scripts/verify-cascade.sh

Nothing is pushed while it does. The stack is still local, and
gh stack rebase --abort restores every branch to the recorded tips."
fi

# --- what this push will rewrite -------------------------------------

step "what changes on the remote"
rewrites=0
while IFS=$'\t' read -r pos head base before; do
  [ -n "$head" ] || continue
  [ "$pos" != 0 ] || continue
  after=$(git rev-parse --verify --quiet "refs/heads/$head" || true)
  [ -n "$after" ] || continue
  if [ "$before" = "$after" ]; then
    printf '  %-40s unchanged\n' "$head"
    continue
  fi
  remote=$(git rev-parse --verify --quiet "refs/remotes/origin/$head" || true)
  if [ -z "$remote" ]; then
    printf '  %-40s new on origin\n' "$head"
  elif git merge-base --is-ancestor "$remote" "$after" 2>/dev/null; then
    printf '  %-40s fast-forward\n' "$head"
  else
    printf '  %-40s REWRITE (%s -> %s)\n' "$head" \
      "$(git rev-parse --short "$remote")" "$(git rev-parse --short "$after")"
  fi
  rewrites=$((rewrites + 1))
done <<EOF
$(awk -F'\t' '$1 == "member" { print $2 "\t" $3 "\t" $4 "\t" $5 }' "$STATE")
EOF

if [ "$rewrites" = 0 ]; then
  printf '\nNo branch moved, so there is nothing to push. Removing the recording.\n'
  rm -f "$STATE"
  exit 0
fi

# --- push ------------------------------------------------------------

step "pushing through gh stack sync"
printf 'force-with-lease and atomic: the lease refuses a branch that moved\n'
printf 'underneath this machine, and the remote takes all of them or none.\n\n'
status=0
gh stack sync || status=$?

if [ "$status" != 0 ]; then
  printf '\ngh stack sync exited %s.\n\n' "$status"
  printf 'A refused lease means a branch moved on the remote after this cascade\n'
  printf 'started, and the copy here would discard it. Fetch, read what arrived,\n'
  printf 'and cascade again from that. Nothing partial reached the remote: the\n'
  printf 'push is atomic.\n'
  exit 1
fi

step "pushed"
rm -f "$STATE"
printf 'removed the recording; it described a cascade that has now landed.\n\n'
gh stack view --short 2>/dev/null || true
printf '\nThe pull requests are relinked as a stack on GitHub. Merging them runs\n'
printf 'bottom-up through the merge-pr-stack skill.\n'
