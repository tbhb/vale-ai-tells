#!/usr/bin/env bash
# advance-stack — establish that a member's merge propagated through the
# rest of the stack, and say what merges next.
#
# GitHub retargets and rebases the remaining members after the bottom
# one merges, and it does that asynchronously. The gap matters: a
# session that merges and immediately reads the next member sees it
# still pointing at a branch that no longer exists, decides the stack is
# broken, and reaches for a rebase nobody needed. So this waits for the
# retarget rather than sampling once.
#
# It prints one line per event, the way watch-checks.sh does, so the
# same command works armed through Monitor and run blocking through
# Bash. A wait that prints nothing until it ends cannot be told from a
# wait that has hung, and under Monitor that silence is the documented
# failure. So each member reports the moment its retarget lands, rather
# than all of them reporting at the close.
#
# It waits and it reports. Nothing here rewrites a branch or pushes one.
# Where the cascade leaves a member GitHub could not rebase on its own,
# that is a real conflict, and it belongs to rebase-pr-stack with an
# operator watching rather than to a loop.
#
# Usage: advance-stack.sh <merged-number>
# Exit:  0 the stack is ready for the next merge, 1 something needs the
#        agent's attention.
set -euo pipefail

# --- environment hardening -------------------------------------------
export LC_ALL=C
export GH_PAGER=cat
export GH_PROMPT_DISABLED=1
export PYTHONUTF8=1
unset CDPATH GH_REPO GH_HOST GREP_OPTIONS
IFS=$' \t\n'

readonly RETARGET_TIMEOUT=${STACK_RETARGET_TIMEOUT:-300}
readonly POLL_INTERVAL=${STACK_RETARGET_POLL:-15}
readonly PR_CAP=${STACK_PREFLIGHT_PRS:-100}

# Every event goes out unbuffered and on its own line. Monitor turns
# each one into a notification, and a line that sits in a buffer is a
# notification that arrives after the thing it describes stopped
# mattering.
emit() {
  printf '%s\n' "$*"
}

root=$(git rev-parse --show-toplevel)
cd "$root"

command -v gh >/dev/null 2>&1 || {
  emit "ERROR gh is not installed"
  exit 1
}

merged=${1:-}
if [ -z "$merged" ]; then
  emit "ERROR no number given; pass the number merge-pr just landed"
  exit 1
fi

state=$(gh pr view "$merged" --json state --jq '.state' 2>/dev/null || echo UNKNOWN)
if [ "$state" != MERGED ]; then
  emit "ERROR #${merged} is ${state}, not MERGED; nothing has cascaded"
  exit 1
fi
emit "MERGED #${merged}"

# --- the retarget ----------------------------------------------------
#
# A member that still has to move has a base that no open pull request
# publishes and that the remote no longer carries. Both halves matter:
# the trunk is published by nothing and is not stale, and a branch
# mid-cascade exists for a moment without a pull request of its own.

stale_bases() {
  gh pr list --state open --limit "$PR_CAP" \
    --json number,headRefName,baseRefName \
    --jq '.[] | [.number, .headRefName, .baseRefName] | @tsv' 2>/dev/null |
    awk -F'\t' '
      { num[NR] = $1; base[NR] = $3; published[$2] = 1; n = NR }
      END { for (i = 1; i <= n; i++) if (!published[base[i]]) print num[i] "\t" base[i] }
    ' | while IFS=$'\t' read -r pr base; do
    git show-ref --verify --quiet "refs/remotes/origin/$base" ||
      printf '%s\t%s\n' "$pr" "$base"
  done
}

git fetch --quiet --prune origin 2>/dev/null || true
pending=$(stale_bases || true)

if [ -n "$pending" ]; then
  emit "WAITING $(printf '%s\n' "$pending" | grep -c .) member(s) still to retarget"
fi

waited=0
while [ -n "$pending" ]; do
  if [ "$waited" -ge "$RETARGET_TIMEOUT" ]; then
    printf '%s\n' "$pending" | while IFS=$'\t' read -r pr base; do
      emit "STUCK #${pr} still based on ${base}, which no longer exists"
    done
    emit "TIMEOUT after ${RETARGET_TIMEOUT}s"
    emit "Read these on GitHub. Retargeting by hand is a base change, which is"
    emit "a decision rather than a step in a loop. Stop here."
    exit 1
  fi

  sleep "$POLL_INTERVAL"
  waited=$((waited + POLL_INTERVAL))
  git fetch --quiet --prune origin 2>/dev/null || true

  now=$(stale_bases || true)
  # Whatever left the pending set since the last look has landed. Naming
  # each one as it lands is the reason this loop prints at all.
  printf '%s\n' "$pending" | while IFS=$'\t' read -r pr base; do
    [ -n "$pr" ] || continue
    printf '%s\n' "$now" | grep -q "^${pr}	" ||
      emit "RETARGETED #${pr} (was on ${base})"
  done
  pending=$now
done

emit "SETTLED every open pull request points at a base that exists (${waited}s)"

# --- local branches --------------------------------------------------
#
# GitHub rebased the remaining members on the remote. A local copy of
# one of those is now behind a branch it cannot fast-forward to, and a
# session that checks one out and pushes undoes the cascade. Naming them
# is the whole job here; moving them belongs to rebase-pr-stack, where a
# range-diff reports what the replay did.

diverged=0
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  git show-ref --verify --quiet "refs/heads/$ref" || continue
  git show-ref --verify --quiet "refs/remotes/origin/$ref" || continue
  counts=$(git rev-list --left-right --count "refs/heads/$ref...refs/remotes/origin/$ref" 2>/dev/null || true)
  [ -n "$counts" ] || continue
  ahead=${counts%%	*}
  behind=${counts##*	}
  if [ "$ahead" != 0 ] && [ "$behind" != 0 ]; then
    emit "DIVERGED ${ref} (${ahead} ahead, ${behind} behind origin)"
    diverged=$((diverged + 1))
  fi
done <<EOF
$(gh pr list --state open --limit "$PR_CAP" --json headRefName --jq '.[].headRefName' 2>/dev/null || true)
EOF

if [ "$diverged" != 0 ]; then
  emit "The remote is the copy to keep; GitHub rebased these. Bring them across"
  emit "through rebase-pr-stack before working on any of them. The next merge"
  emit "does not need them: merge-pr reads the pull request, not the worktree."
fi

emit "NEXT re-run the merge-pr-stack preflight; the member that was second is the bottom now"
