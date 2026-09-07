#!/usr/bin/env bash
# stack-chain — print the members of a stack in order, bottom first.
#
# The chain comes from the base pointers on the open pull requests. The
# gh stack extension keeps tracking of its own, but a stack assembled by
# setting a base on each pull request leaves nothing on this machine,
# and a session standing on the default branch is not in a stack as far
# as the extension is concerned. GitHub always knows the shape.
#
# Every other script in this skill orders itself by this one, so the
# shape it prints is the skill's internal contract: one tab-separated
# line per member, position first, then number, head branch, and base
# branch. Position 1 is the bottom, and its base is the trunk.
#
# An error prints as a single line starting ERR, because a caller that
# reads the first field can tell the two apart without parsing prose.
#
# Read-only. Usage: stack-chain.sh <pull-request-number>
set -euo pipefail

export LC_ALL=C
export GH_PAGER=cat
export GH_PROMPT_DISABLED=1
export PYTHONUTF8=1
unset CDPATH GH_REPO GH_HOST GREP_OPTIONS
IFS=$' \t\n'

readonly PR_CAP=${STACK_PREFLIGHT_PRS:-100}

start=${1:-}
[ -n "$start" ] || {
  printf 'ERR\tno-number\n'
  exit 0
}

gh pr list --state open --limit "$PR_CAP" \
  --json number,headRefName,baseRefName,title \
  --jq '.[] | [.number, .headRefName, .baseRefName, .title] | @tsv' 2>/dev/null |
  awk -F'\t' -v start="$start" '
    NF >= 3 { head[$1] = $2; base[$1] = $3; title[$1] = $4; byhead[$2] = $1; seen[$1] = 1 }
    END {
      if (!seen[start]) { print "ERR\tnot-open"; exit }

      # Down to the bottom, following each base to whichever pull
      # request publishes that branch. A base nothing publishes is the
      # trunk, and the walk stops there.
      n = 0; cur = start
      while (1) {
        down[++n] = cur
        parent = byhead[base[cur]]
        if (parent == "" || parent == cur || n > 50) break
        cur = parent
      }
      m = 0
      for (i = n; i >= 1; i--) ord[++m] = down[i]

      # Up from the named pull request. Two members sharing one base is
      # a tree rather than a stack, and nothing here knows which limb
      # the caller meant.
      cur = start
      while (m <= 50) {
        found = ""; cnt = 0
        for (k in seen) if (base[k] == head[cur]) { found = k; cnt++ }
        if (cnt == 0) break
        if (cnt > 1) { printf "ERR\tbranching\t%s\n", head[cur]; exit }
        ord[++m] = found
        cur = found
      }

      for (i = 1; i <= m; i++)
        printf "%d\t%s\t%s\t%s\t%s\n", i, ord[i], head[ord[i]], base[ord[i]], title[ord[i]]
    }
  '
