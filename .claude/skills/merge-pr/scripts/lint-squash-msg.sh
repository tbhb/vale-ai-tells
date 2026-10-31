#!/usr/bin/env bash
# Run the repository's squash-message gates against dictionaries from the
# pull request head rather than whichever branch the operator has checked out.
set -euo pipefail

export LC_ALL=C
export GH_PAGER=cat
export GH_PROMPT_DISABLED=1
export PYTHONUTF8=1
unset CDPATH GH_REPO GH_HOST GREP_OPTIONS
IFS=$' \t\n'

# shellcheck disable=SC1091 # generated beside this script
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck disable=SC1091 # generated beside this script
. "$DT_LIB_DIR/pull-request.sh"

readonly DRAFT=SQUASH_AGENTMSG

root=$(dt_root)
cd "$root"
state=$(dt_state_dir)

number=${1:-}
if [ -z "$number" ]; then
  subject=$(head -1 "$DRAFT")
  number=$(printf '%s' "$subject" | sed -n 's/.*(#\([0-9][0-9]*\))[[:space:]]*$/\1/p')
fi
case $number in "" | *[!0-9]*) dt_die "Pass the pull request number or name it at the end of the squash subject." ;; esac

view=$state/squash-lint.view.json
mp_view "$number" "$view" number,headRefOid || exit $?
head=$(mp_field "$view" headRefOid) || exit $?
case $head in "" | *[!0-9a-f]*) dt_die "Pull request #$number has no valid head commit." ;; esac
[ "${#head}" -eq 40 ] || dt_die "Pull request #$number has no full head commit."

ma_lint "$head"
