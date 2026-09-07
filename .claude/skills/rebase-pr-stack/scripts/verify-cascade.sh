#!/usr/bin/env bash
# verify-cascade — read what the cascade did to every branch, not just
# that it finished.
#
# A cascade reports success when every commit applied. Two failures live
# past that. A resolution can lose a hunk, leaving a commit that still
# applies and still carries a message describing the change it no longer
# makes. And a tree can break with no commit at fault, where the trunk
# adds a gate that a branch's own files fail, a combination that first
# exists here.
#
# This is the step `gh stack sync` has no room for, because sync rebases
# and pushes in one operation. start-cascade.sh recorded each branch's
# pre-cascade tip; this pairs each one against its replayed self.
#
# Read-only. It reports; the SKILL.md steps act.
#
# Usage: verify-cascade.sh
# Exit:  0 nothing to flag, 1 something needs the agent's attention.
set -euo pipefail

# --- environment hardening -------------------------------------------
export LC_ALL=C
export PYTHONUTF8=1
unset CDPATH GREP_OPTIONS
IFS=$' \t\n'

section() { printf '\n== %s ==\n' "$1"; }
none() { printf '(none)\n'; }

readonly RANGE_DIFF_CAP=${STACK_VERIFY_RANGE_DIFF_LINES:-200}

root=$(git rev-parse --show-toplevel)
cd "$root"
git_dir=$(git rev-parse --absolute-git-dir)
here=${BASH_SOURCE%/*}
readonly STATE="$git_dir/stack-rebase-state"
flagged=0

if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
  printf 'A rebase is still in progress. Finish the cascade before verifying it.\n' >&2
  exit 1
fi

[ -s "$STATE" ] || {
  printf 'verify-cascade: no recording at %s.\n' "${STATE#"$root"/}" >&2
  printf 'start-cascade.sh writes it before it moves anything, and without it\n' >&2
  printf 'there is no pre-cascade tip to compare against. Nothing here can say\n' >&2
  printf 'what the replay did.\n' >&2
  exit 1
}

trunk=$(awk -F= '$1 == "trunk" { print $2 }' "$STATE")
was_on=$(awk -F= '$1 == "was_on" { print $2 }' "$STATE")

section "the recording"
printf 'started: %s\n' "$(awk -F= '$1 == "started" { print $2 }' "$STATE")"
printf 'trunk:   %s\n' "$trunk"
printf 'was on:  %s (now on %s)\n' "$was_on" "$(git rev-parse --abbrev-ref HEAD)"

# --- per-branch replay -----------------------------------------------
#
# Each member is measured against the member below it, before and
# after. Naming both ranges rather than using the three-dot shorthand
# matters: after a rebase the merge base of the two tips is the old
# parent, so a three-dot range swallows everything the parent
# contributed and every commit on the branch reads as dropped and
# re-added.

section "what the replay did to each branch"
members=$(awk -F'\t' '$1 == "member" && $2 != 0 { print $2 "\t" $3 "\t" $4 "\t" $5 }' "$STATE")
[ -n "$members" ] || {
  printf 'The recording names no members.\n'
  exit 1
}

prev_before=$(awk -F'\t' '$1 == "member" && $2 == 0 { print $5 }' "$STATE")
prev_branch=$trunk

while IFS=$'\t' read -r pos head base before; do
  [ -n "$head" ] || continue
  printf '\n--- #%s %s (on %s)\n' "$pos" "$head" "$prev_branch"

  after=$(git rev-parse --verify --quiet "refs/heads/$head" || true)
  parent_after=$(git rev-parse --verify --quiet "refs/heads/$prev_branch" ||
    git rev-parse --verify --quiet "refs/remotes/origin/$prev_branch" || true)

  if [ -z "$before" ]; then
    printf 'no pre-cascade tip was recorded, so nothing can be compared here.\n'
    flagged=1
  elif [ -z "$after" ]; then
    printf 'the branch no longer exists locally. The cascade should never remove\n'
    printf 'one; read the stack before going on.\n'
    flagged=1
  elif [ "$before" = "$after" ]; then
    printf 'unchanged (%s). Nothing replayed.\n' "$(git rev-parse --short "$before")"
  else
    printf '%s -> %s\n\n' "$(git rev-parse --short "$before")" "$(git rev-parse --short "$after")"
    old_base=$(git merge-base "$prev_before" "$before" 2>/dev/null || true)
    new_base=$(git merge-base "$parent_after" "$after" 2>/dev/null || true)
    if [ -z "$old_base" ] || [ -z "$new_base" ]; then
      printf 'could not find a merge base on one side, so the ranges cannot pair.\n'
      flagged=1
    else
      old_count=$(git rev-list --count "$old_base..$before")
      new_count=$(git rev-list --count "$new_base..$after")
      if [ "$new_count" = 0 ] && [ "$old_count" != 0 ]; then
        printf 'This branch now carries no commits of its own, where it carried %s\n' "$old_count"
        printf 'before. Every one applied as empty and was dropped. Check the branch\n'
        printf 'below before concluding the work is gone: an identical change already\n'
        printf 'there produces exactly this.\n'
        flagged=1
      else
        # --creation-factor is raised from its default of 60 because
        # this is a replay rather than a rewritten series. A commit
        # whose resolution changed much of a small patch falls outside
        # the default window and reports as one dropped and one
        # created, which reads as loss where none happened.
        rd=$(git --no-pager -c color.ui=false range-diff --no-color \
          --creation-factor=90 "$old_base..$before" "$new_base..$after" 2>/dev/null || true)
        if [ -z "$rd" ]; then
          printf 'range-diff produced nothing for this pair.\n'
          flagged=1
        elif [ "$(printf '%s\n' "$rd" | wc -l)" -le "$RANGE_DIFF_CAP" ]; then
          printf '%s\n' "$rd"
        else
          printf '%s\n' "$rd" | grep -E '^[ 0-9-]+: +[0-9a-f-]+ [!<>=]' || true
          printf '\n(the per-commit diff runs past %s lines; the pairing above is the\n' "$RANGE_DIFF_CAP"
          printf 'summary. Read a ! with:\n'
          printf '  git range-diff %s..%s %s..%s)\n' \
            "$(git rev-parse --short "$old_base")" "$(git rev-parse --short "$before")" \
            "$(git rev-parse --short "$new_base")" "$(git rev-parse --short "$after")"
        fi
        if printf '%s\n' "$rd" | grep -qE '^ *[0-9]+: +[0-9a-f]+ <'; then
          printf '\nA commit from the old branch has no counterpart here. Either the\n'
          printf 'replay dropped it or a resolution changed it past recognition. Say\n'
          printf 'which before going on.\n'
          flagged=1
        fi
      fi
    fi
  fi

  prev_before=$before
  prev_branch=$head
done <<EOF
$members
EOF

printf '\nRead each pairing before its diff. = means the commit replayed\n'
printf 'unchanged. ! means its content moved, expected where a conflict was\n'
printf 'resolved and suspicious everywhere else. A < or > means a commit\n'
printf 'vanished or appeared.\n'

# --- conflict markers ------------------------------------------------

section "conflict markers on the branch tips"
found=""
while IFS=$'\t' read -r pos head base before; do
  [ -n "$head" ] || continue
  git show-ref --verify --quiet "refs/heads/$head" || continue
  candidates=()
  while IFS= read -r path; do
    [ -n "$path" ] && candidates+=("$path")
  done <<INNER
$(git grep -l -E '^(<<<<<<<|>>>>>>>|\|\|\|\|\|\|\|)( |$)' "refs/heads/$head" -- 2>/dev/null |
  sed "s|^refs/heads/$head:||" || true)
INNER
  [ "${#candidates[@]}" -gt 0 ] || continue
  # marker-scan.sh decides which candidates are real, so a file whose
  # subject is conflict markers stops being reported here forever. The
  # rebase skill owns it; without that skill the candidates stand as
  # they are, named rather than judged.
  if [ -f "$here/../../rebase/scripts/marker-scan.sh" ]; then
    hits=$(bash "$here/../../rebase/scripts/marker-scan.sh" "${candidates[@]}" || true)
  else
    hits=$(printf '%s\n' "${candidates[@]}")
  fi
  if [ -n "$hits" ]; then
    printf '%s:\n%s\n' "$head" "$hits"
    found=1
  fi
done <<EOF
$members
EOF
if [ -n "$found" ]; then
  printf '\nThese are committed, not merely present in the worktree. Every one is a\n'
  printf 'resolution that never finished. Fix them before anything is pushed.\n'
  flagged=1
else
  none
fi

section "working tree"
dirty=$(git status --porcelain=v1 2>/dev/null || true)
if [ -n "$dirty" ]; then
  printf '%s\n' "$dirty"
  printf '\nThe cascade should leave the tree clean. Anything here came out of a\n'
  printf 'resolution and belongs in a commit or out of the way before the push.\n'
  flagged=1
else
  none
fi

section "gates to run"
# The cascade produced a tree no commit ever tested. Naming the task
# rather than running it keeps a failure in the agent's own terminal
# with its full context.
if command -v mise >/dev/null 2>&1; then
  ran=0
  for task in check lint; do
    if mise task info "$task" >/dev/null 2>&1; then
      printf 'mise run %s\n' "$task"
      ran=1
      break
    fi
  done
  [ "$ran" = 1 ] || printf '(no check or lint task in this repository)\n'
  printf '\nRun it on the top of the stack at least, where every change in the\n'
  printf 'stack is present at once. Each commit passed the hooks in isolation;\n'
  printf 'this combination has never been tested.\n'
else
  printf 'mise is not installed; there is nothing to run here.\n'
fi

section "verdict"
if [ "$flagged" = 0 ]; then
  printf 'Nothing flagged. The push is the next step:\n\n'
  printf '  bash .claude/skills/rebase-pr-stack/scripts/push-stack.sh\n'
else
  printf 'Something above needs an answer before anything is pushed. The stack is\n'
  printf 'still local, and gh stack rebase --abort restores every branch to the\n'
  printf 'tips the recording holds.\n'
fi

exit "$flagged"
