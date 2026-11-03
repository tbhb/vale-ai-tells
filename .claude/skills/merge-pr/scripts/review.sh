#!/usr/bin/env bash
# review — run the independent review of SQUASH_AGENTMSG against every
# commit the squash collapses, and stamp the draft when it passes.
#
# The script takes one snapshot first: a copy of the draft, and one gh
# response for the pull request that names its head and base. The
# title, description, and commit messages come from that response. The
# diff and changed files come from local git objects fetched at the
# pinned head and base commits. All inputs land in this run's directory.
# The stamp binds the copy's bytes, the pull request number, the
# head, the base branch, the commit the base pointed at, and any
# operator note. Before stamping, the script reads the live pull request
# again and refuses when the head, the base, or the base's commit moved,
# so the stamp cannot cover a branch the reviewer never read.
#
# The reviewer is a fresh, read-only process this script starts, so no
# harness hook has to fire and the caller never handles the verdict.
# Its criteria are the review-squash-message skill deployed beside this
# one.
#
# Usage: review.sh [--note <file>] [number]
#   number  defaults to the one the draft's subject names
# Exit:  0 stamped, 2 changes required, 4 no readable verdict or the
#        reviewer failed, 75 waiting on required reviews, 5 the draft or
#        the pull request changed during the review, 1 refused beforehand.
set -euo pipefail

# --- environment hardening -------------------------------------------
# lib.sh repeats this block; it stays here too so the hygiene gate can
# see it in the file that calls git and gh.
export LC_ALL=C
export GH_PAGER=cat
export GH_PROMPT_DISABLED=1
export PYTHONUTF8=1
unset CDPATH GH_REPO GH_HOST GREP_OPTIONS
IFS=$' \t\n'

# shellcheck disable=SC1091 # lib.sh is generated beside this script
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck disable=SC1091 # generated beside this script
. "$DT_LIB_DIR/pull-request.sh"

usage="usage: review.sh [--note <file>] [number]"
note=""
number=""
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
  -*) dt_die "$usage" ;;
  *)
    [ -z "$number" ] || dt_die "$usage"
    number=$1
    shift
    ;;
  esac
done

mp_need_tools
root=$(dt_root)
cd "$root"
ma_context
draft=$root/SQUASH_AGENTMSG
[ -s "$draft" ] || dt_die "SQUASH_AGENTMSG is missing or empty. Run squash-message.sh and write the body first."
drafted_for=$(head -n 1 "$draft" | sed -n 's/.*(#\([0-9][0-9]*\))[[:space:]]*$/\1/p')
[ -n "$drafted_for" ] || dt_die "The subject of SQUASH_AGENTMSG names no pull request; it has to end in (#<number>)."
[ -n "$number" ] || number=$drafted_for
case $number in
*[!0-9]*) dt_die "$usage" ;;
esac
[ "$drafted_for" = "$number" ] || dt_die "SQUASH_AGENTMSG was drafted for #$drafted_for, not #$number."

# The snapshot. Everything the reviewer reads derives from this one
# response, which names the head and the base it describes.
inputs=$(dt_new_inputs squash)
view=$inputs/pull-request.json
mp_view "$number" "$view" "$MA_GATE_FIELDS,number,title,body,headRefName,commits,reviewDecision" || exit $?
pr_state=$(mp_field "$view" state) || exit $?
[ "$pr_state" = OPEN ] || dt_die "#$number is $pr_state, not OPEN."
mp_require_reviews "$view" "$number"
head=$(mp_field "$view" headRefOid)
base=$(mp_field "$view" baseRefName)
[ -n "$head" ] && [ -n "$base" ] || dt_die "#$number names no head or no base."
if [ "${DEVTOOLS_UNATTENDED:-0}" = 1 ]; then ma_lint "$head"; fi
base_oid=$(mp_base_oid "$base") || exit $?
[ -n "$base_oid" ] || dt_die "Could not read where $base points."
ma_gates "$view" "$number" "$base_oid"

snapshot=$inputs/SQUASH_AGENTMSG
cp "$draft" "$snapshot"
note_digest=none
if [ -n "$note" ]; then
  cp "$note" "$inputs/operator-note.txt"
  note_digest=$(dt_digest "$inputs/operator-note.txt")
fi

jq -r '
  "number: #\(.number)",
  "title: \(.title)",
  "\(.headRefName) into \(.baseRefName)",
  "head oid: \(.headRefOid)"
' "$view" >"$inputs/pull-request.txt"
printf 'base oid: %s\n' "$base_oid" >>"$inputs/pull-request.txt"
jq -r '.body // ""' "$view" >"$inputs/description.md"
# Bodies in full rather than subjects. A subject names what a commit
# did, the body carries why, and the reason is the first thing a squash
# loses.
jq -r '.commits[] | "--- " + .oid + "\n" + .messageHeadline + "\n\n" + (.messageBody // "") + "\n"' \
  "$view" >"$inputs/commits.txt"
rm -f "$view"
mp_local_diff "$base_oid" "$head" "$inputs"
mergebase=$(gitr merge-base "$base_oid" "$head")
gitr log --reverse --format='--- %H%n%B' "$mergebase..$head" >"$inputs/commits.txt"

# shellcheck disable=SC2329 # dt_review calls it by name
still_as_gathered() {
  local live live_base
  live=$(dt_state_dir)/squash.live.json
  mp_view "$number" "$live" headRefOid,baseRefName,reviewDecision || exit $?
  mp_require_reviews "$live" "$number"
  local live_head live_name
  live_head=$(mp_field "$live" headRefOid) || return $?
  live_name=$(mp_field "$live" baseRefName) || return $?
  [ "$live_head" = "$head" ] && [ "$live_name" = "$base" ] || return 1
  live_base=$(mp_base_oid "$base") || exit $?
  [ "$live_base" = "$base_oid" ] &&
    { [ "$note_digest" = none ] || {
      local live_note_digest
      live_note_digest=$(dt_digest "$inputs/operator-note.txt") || return $?
      [ "$live_note_digest" = "$note_digest" ]
    }; }
}

dt_review_policy "$inputs" "$head" "$head"

criteria=$DT_LIB_DIR/../../review-squash-message/SKILL.md
status=0
dt_review squash "$draft" "$snapshot" "$criteria" "$root" "$inputs" still_as_gathered \
  "pr:$number:$head" \
  pr "$number" head "$head" base "$base" base_oid "$base_oid" note "$note_digest" || status=$?
state=$(dt_state_dir) || exit $?
rm -f "$state/squash.live.json"
case $status in
0) ;;
2) printf '\nFix every finding in SQUASH_AGENTMSG, then run review.sh again.\n' ;;
esac
exit "$status"
