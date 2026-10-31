#!/usr/bin/env bash
# review — run the independent review of PR_AGENTDESC.md against the
# branch it would publish, and stamp the draft when it passes.
#
# The script takes one snapshot first, in a directory of this run's own:
# a copy of the draft, the commit at HEAD, the base the draft names
# resolved to a ref (origin's copy where one exists, else the local
# branch), that ref's commit, and the merge base. The commits, the
# changed paths, the diff, and the template the reviewer reads all come
# from those recorded commits, never from a live ref or the working
# tree. The stamp binds the copy's bytes and every one of those values.
# Before stamping, the script confirms that the live draft and the live
# refs still match the snapshot, so the stamp cannot cover a branch or a
# base the reviewer never read, and create-pr.sh refuses when any of
# them has moved since.
#
# The reviewer is a fresh, read-only process this script starts, so no
# harness hook has to fire and the caller never handles the verdict. Its
# criteria are the review-pr-description skill deployed beside this one.
#
# Usage: review.sh [--note <file>]
# Exit:  0 stamped, 2 changes required, 4 no readable verdict or the
#        reviewer failed, 5 the draft, HEAD, or the base moved during
#        the review, 1 refused before reviewing.
set -euo pipefail

# --- environment hardening -------------------------------------------
# lib.sh repeats this block; it stays here too so the hygiene gate can
# see it in the file that calls git.
export LC_ALL=C
export GH_PAGER=cat
export GH_PROMPT_DISABLED=1
export PYTHONUTF8=1
unset CDPATH GH_REPO GH_HOST GREP_OPTIONS
IFS=$' \t\n'

# shellcheck disable=SC1091 # lib.sh is generated beside this script
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck disable=SC1091 # description.sh is deployed beside this script
. "$DT_LIB_DIR/description.sh"
# shellcheck disable=SC1091 # unattended entry point shares this review
. "$DT_LIB_DIR/pr-agent.sh"

usage="usage: review.sh [--note <file>]"
note=""
while [ $# -gt 0 ]; do
  case $1 in
  --note)
    [ $# -ge 2 ] || dt_die "$usage"
    [ -f "$2" ] || dt_die "Operator note is not a file: $2"
    note_dir=$(dirname "$2") || exit $?
    note_name=$(basename "$2") || exit $?
    note_dir=$(cd "$note_dir" && pwd) || exit $?
    note=$note_dir/$note_name
    shift 2
    ;;
  *) dt_die "$usage" ;;
  esac
done

root=$(dt_root)
cd "$root"
pr_agent_context
branch=$(gitr symbolic-ref --short HEAD)
draft=$root/PR_AGENTDESC.md
[ -s "$draft" ] || dt_die "PR_AGENTDESC.md is missing or empty. Draft the description first."
bash "$DT_LIB_DIR/validate-description.sh" "$draft"
gitr symbolic-ref -q HEAD >/dev/null || dt_die "HEAD is detached. Check out the branch to review."
current_head=$(dt_head) || exit $?
[ "$current_head" != unborn ] || dt_die "The branch has no commit yet."

# The snapshot. Everything the reviewer reads derives from the copy of
# the draft and the commits recorded here.
inputs=$(dt_new_inputs pr)
snapshot=$inputs/PR_AGENTDESC.md
cp "$draft" "$snapshot"
base=$(pr_field "$snapshot" base)
[ -n "$base" ] || dt_die "The draft's frontmatter carries no base."
base_ref=$(pr_base_ref "$base")
pr_agent_range "$base_ref"
[ -n "$base_ref" ] || dt_die "The draft's base, $base, names no local or origin branch."
head=$(dt_head)
base_oid=$(gitr rev-parse --verify "$base_ref^{commit}")
mergebase=$(gitr merge-base "$base_oid" "$head") || dt_die "No merge base between $base_ref and HEAD."
note_digest=none
if [ -n "$note" ]; then
  cp "$note" "$inputs/operator-note.txt"
  note_digest=$(dt_digest "$inputs/operator-note.txt")
fi

# The diff as text, whatever the attributes and the environment say: no
# external diff program, no text conversion, and no file shown as
# binary. A branch that names paths but produces no diff means
# something hid it.
printf 'base: %s (%s at %s)\nmerge base: %s\nhead: %s\n' \
  "$base" "$base_ref" "$base_oid" "$mergebase" "$head" >"$inputs/range.txt"
gitr log --reverse --pretty=format:'--- %h%n%B' "$mergebase..$head" >"$inputs/commits.txt"
gitr diff --no-ext-diff --no-textconv --no-renames --name-status "$mergebase" "$head" >"$inputs/changed-paths.txt"
gitr diff --no-ext-diff --text --no-textconv --no-renames "$mergebase" "$head" >"$inputs/branch.diff"
if [ -s "$inputs/changed-paths.txt" ] && [ ! -s "$inputs/branch.diff" ]; then
  dt_die "The branch names changed paths, but its diff is empty; something is hiding the content."
fi
template=$(pr_template)
if gitr cat-file -e "$head:$template" 2>/dev/null; then
  gitr cat-file -p "$head:$template" >"$inputs/pull_request_template.md"
fi

# shellcheck disable=SC2329 # dt_review calls it by name
still_as_gathered() {
  local live_head live_ref live_oid live_branch
  live_head=$(dt_head) || return $?
  live_branch=$(gitr symbolic-ref --short HEAD) || return $?
  live_ref=$(pr_base_ref "$base") || return $?
  live_oid=$(gitr rev-parse --verify --quiet "$base_ref^{commit}") || return $?
  [ "$live_branch" = "$branch" ] && [ "$live_head" = "$head" ] && [ "$live_ref" = "$base_ref" ] && [ "$live_oid" = "$base_oid" ] &&
    { [ "$note_digest" = none ] || {
      local live_note_digest
      live_note_digest=$(dt_digest "$inputs/operator-note.txt") || return $?
      [ "$live_note_digest" = "$note_digest" ]
    }; }
}

dt_review_policy "$inputs" "$head" "$head"

criteria=$DT_LIB_DIR/../../review-pr-description/SKILL.md
status=0
dt_review pr "$draft" "$snapshot" "$criteria" "$root" "$inputs" still_as_gathered \
  "branch:$branch:$head" \
  head "$head" base "$base_ref" base_oid "$base_oid" mergebase "$mergebase" note "$note_digest" branch "$branch" || status=$?
case $status in
0) ;;
2) printf '\nResolve every finding in the draft, then run review.sh again.\n' ;;
esac
exit "$status"
