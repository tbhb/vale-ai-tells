#!/usr/bin/env bash
# review — run the independent review of COMMIT_AGENTMSG against the
# staged change, and stamp the draft when it passes.
#
# The script takes one snapshot first: the staged tree, the commit at
# HEAD, and a copy of the draft, in a directory of this run's own. The
# diff the reviewer reads comes from that tree and that commit, never
# from the live index. The stamp binds the copy's bytes, the tree, the
# commit, and whether the review read an amend. Before stamping, the
# script confirms that the live draft, index, and HEAD still match the
# snapshot, so the stamp cannot cover bytes the reviewer never had.
#
# The reviewer is a fresh, read-only process this script starts, so no
# harness hook has to fire and the caller never handles the verdict.
# Its criteria are the review-commit-message skill deployed beside this
# one. For an amend, the diff is the amended commit's whole content,
# against the parent of HEAD. Before the first commit, the diff is
# against the empty tree.
#
# Usage: review.sh [--amend] [--note <file>]
# Exit:  0 stamped, 2 changes required, 4 no readable verdict or the
#        reviewer failed, 5 the draft, index, or HEAD changed during the
#        review, 1 refused before reviewing.
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

mode=normal
arguments_suffix=""
note=""
while [ $# -gt 0 ]; do
  case $1 in
  --amend)
    mode=amend
    arguments_suffix=" --amend"
    shift
    ;;
  --note)
    [ $# -ge 2 ] || dt_die "usage: review.sh [--amend] [--note <file>]"
    [ -f "$2" ] || dt_die "Operator note is not a file: $2"
    note_dir=$(dirname "$2") || exit $?
    note_name=$(basename "$2") || exit $?
    note_dir=$(cd "$note_dir" && pwd) || exit $?
    note=$note_dir/$note_name
    shift 2
    ;;
  *) dt_die "usage: review.sh [--amend] [--note <file>]" ;;
  esac
done

root=$(dt_root)
cd "$root"
draft=$root/COMMIT_AGENTMSG
[ -s "$draft" ] || dt_die "COMMIT_AGENTMSG is missing or empty. Draft the message first."

# The snapshot. Everything the reviewer reads derives from these three.
tree=$(gitr write-tree)
head=$(dt_head)
[ "$mode" = normal ] || [ "$head" != unborn ] || dt_die "There is no commit to amend yet."
inputs=$(dt_new_inputs commit)
snapshot=$inputs/COMMIT_AGENTMSG
cp "$draft" "$snapshot"
note_digest=none
if [ -n "$note" ]; then
  cp "$note" "$inputs/operator-note.txt"
  note_digest=$(dt_digest "$inputs/operator-note.txt")
fi

empty_tree=$(gitr hash-object -t tree /dev/null)
case $mode:$head in
*:unborn) against=$empty_tree ;;
amend:*) against=$(gitr rev-parse --verify --quiet "$head~1" || printf '%s\n' "$empty_tree") ;;
*) against=$head ;;
esac

# The diff as text, whatever the attributes and the environment say: no
# external diff program, no text conversion, and no file shown as
# binary. A change that names paths but produces no diff means
# something hid it.
gitr diff --no-ext-diff --no-textconv --no-renames --name-status "$against" "$tree" >"$inputs/staged-paths.txt"
gitr diff --no-ext-diff --text --no-textconv --no-renames "$against" "$tree" >"$inputs/staged.diff"
if [ -s "$inputs/staged-paths.txt" ] && [ ! -s "$inputs/staged.diff" ]; then
  dt_die "The staged change names paths, but its diff is empty; something is hiding the content."
fi
if [ "$head" = unborn ]; then
  printf '(no commits yet: this is the first commit)\n' >"$inputs/recent-subjects.txt"
else
  gitr log -5 --pretty=format:'%h %s' "$head" >"$inputs/recent-subjects.txt"
fi

# shellcheck disable=SC2329 # dt_review calls it by name
still_as_gathered() {
  local live_tree live_head
  live_tree=$(gitr write-tree) || return $?
  live_head=$(dt_head) || return $?
  [ "$live_tree" = "$tree" ] && [ "$live_head" = "$head" ] &&
    { [ "$note_digest" = none ] || {
      local live_note_digest
      live_note_digest=$(dt_digest "$inputs/operator-note.txt") || return $?
      [ "$live_note_digest" = "$note_digest" ]
    }; }
}

dt_review_policy "$inputs" "$head" "$tree"

criteria=$DT_LIB_DIR/../../review-commit-message/SKILL.md
status=0
dt_review commit "$draft" "$snapshot" "$criteria" "$root$arguments_suffix" "$inputs" still_as_gathered \
  "tree:$tree" \
  tree "$tree" head "$head" mode "$mode" note "$note_digest" || status=$?
case $status in
0) ;;
2) printf '\nFix every finding in COMMIT_AGENTMSG, then run review.sh again.\n' ;;
esac
exit "$status"
