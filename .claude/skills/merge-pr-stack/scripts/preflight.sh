#!/usr/bin/env bash
# preflight — gather every fact the merge-pr-stack skill needs before it
# merges anything.
#
# The merge-pr-stack SKILL.md inlines this through the !`...`
# preprocessor. It answers the one question that orders the whole run,
# which member merges next, and the ones that decide whether the run
# should start at all.
#
# The chain comes from the base pointers on the open pull requests
# rather than from local stack tracking. Two reasons. A stack reaches
# GitHub through `gh stack submit` or through a `base:` set on each pull
# request, and only the first leaves anything on this machine, so local
# tracking is absent about as often as it is present. And merges run
# from a root session standing on the default branch, where
# `gh stack view` reports that the current branch is not part of a
# stack and stops.
#
# Nothing here mutates anything. Usage: preflight.sh [number|branch]
set -euo pipefail

# --- environment hardening -------------------------------------------
# The agent reads this output, so the operator's preferences must not
# change its shape. LC_ALL pins collation, because sort and the [a-z]
# ranges below mean different things under a UTF-8 locale. The unsets
# cover variables that silently retarget a command: GH_REPO sends gh at
# another repository, CDPATH makes a relative cd print somewhere else.
export LC_ALL=C
export GH_PAGER=cat
export GH_PROMPT_DISABLED=1
export PYTHONUTF8=1
unset CDPATH GH_REPO GH_HOST GREP_OPTIONS
IFS=$' \t\n'

readonly DRAFT=SQUASH_AGENTMSG
readonly PR_CAP=${STACK_PREFLIGHT_PRS:-100}

section() { printf '\n== %s ==\n' "$1"; }
none() { printf '(none)\n'; }

root=$(git rev-parse --show-toplevel)
cd "$root"

section "gh"
gh_state=ok
if ! command -v gh >/dev/null 2>&1; then
  gh_state="gh is not installed"
elif ! gh auth status >/dev/null 2>&1; then
  gh_state="gh is not authenticated — run gh auth login"
fi
printf '%s\n' "$gh_state"
if [ "$gh_state" != ok ]; then
  printf 'Stop here and tell the operator.\n'
  exit 0
fi

# The extension is what a stack is built and rebased with. This skill
# never calls it, because a stack merge writes the message GitHub
# generates, but its absence still says the stack was assembled some
# other way, and that is worth knowing before the run starts.
if gh extension list 2>/dev/null | grep -q 'gh stack'; then
  printf 'gh stack extension: present\n'
else
  printf 'gh stack extension: absent (not needed here; rebase-pr-stack wants it)\n'
fi

branch=$(git rev-parse --abbrev-ref HEAD)
target=${1:-}

section "target"
printf 'local branch: %s\n' "$branch"

# A bare number names a pull request. Anything else names a branch, and
# the branch resolves to whichever open pull request has it as its head.
number=""
case $target in
'') ;;
*[!0-9]*)
  number=$(gh pr list --head "$target" --state open --json number --jq '.[0].number' 2>/dev/null || true)
  [ -n "$number" ] || printf 'no open pull request with head %s\n' "$target"
  ;;
*) number=$target ;;
esac
if [ -z "$number" ] && [ -z "$target" ]; then
  number=$(gh pr list --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || true)
fi

if [ -z "$number" ]; then
  printf 'pull request: NONE resolved, and none given.\n'
  printf 'Pass a number or a branch as the skill argument.\n'
  printf '\nopen pull requests here:\n'
  gh pr list --state open --limit "$PR_CAP" \
    --json number,title,headRefName,baseRefName,isDraft \
    --template '{{range .}}#{{.number}} {{.headRefName}} -> {{.baseRefName}}  {{.title}}{{if .isDraft}} [draft]{{end}}
{{end}}' 2>/dev/null || none
  exit 0
fi
printf 'named pull request: #%s\n' "$number"

# --- the chain -------------------------------------------------------

prs=$(gh pr list --state open --limit "$PR_CAP" \
  --json number,headRefName,baseRefName,title \
  --jq '.[] | [.number, .headRefName, .baseRefName, .title] | @tsv' 2>/dev/null || true)

chain=$(printf '%s\n' "$prs" | awk -F'\t' -v start="$number" '
  NF >= 3 { head[$1] = $2; base[$1] = $3; title[$1] = $4; byhead[$2] = $1; seen[$1] = 1 }
  END {
    if (!seen[start]) { print "ERR\tnot-open"; exit }

    # Walk down to the bottom, following each base to the pull request
    # that publishes it. A base nothing publishes is the trunk, and the
    # walk stops there.
    n = 0; cur = start
    while (1) {
      down[++n] = cur
      parent = byhead[base[cur]]
      if (parent == "" || parent == cur || n > 50) break
      cur = parent
    }
    m = 0
    for (i = n; i >= 1; i--) ord[++m] = down[i]

    # Walk up from the named pull request. Two pull requests sharing one
    # base is a tree rather than a stack, and nothing here knows which
    # limb the operator meant.
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
')

section "the stack"
case $chain in
"ERR	not-open"*)
  printf '#%s is not an open pull request, so there is no chain to walk.\n' "$number"
  exit 0
  ;;
"ERR	branching"*)
  printf 'Two open pull requests share the base %s.\n' "${chain##*$'\t'}"
  printf 'That is a tree rather than a stack, and nothing here can tell which\n'
  printf 'limb you meant. Name the top of the one you want as the argument.\n'
  exit 0
  ;;
esac

depth=$(printf '%s\n' "$chain" | grep -c . || true)
trunk=$(printf '%s\n' "$chain" | head -1 | cut -f4)
printf 'depth: %s\ntrunk: %s\n\n' "$depth" "$trunk"
printf '%s\n' "$chain" | awk -F'\t' -v d="$depth" '
  { printf "%s#%-5s %s -> %s\n      %s\n", ($1 == 1 ? "bottom " : "       "), $2, $3, $4, $5 }
'
printf '\nDerived from base pointers, not from local stack tracking.\n'

# --- per-member readiness --------------------------------------------

section "readiness"
printf '%s\n' "$chain" | cut -f2 | while read -r pr; do
  [ -n "$pr" ] || continue
  gh pr view "$pr" --json number,state,isDraft,mergeable,mergeStateStatus,reviewDecision \
    --template '#{{.number}}  {{.state}}{{if .isDraft}} DRAFT{{end}}  {{.mergeable}}/{{.mergeStateStatus}}  review: {{if .reviewDecision}}{{.reviewDecision}}{{else}}none required{{end}}
' 2>/dev/null || printf '#%s  (could not read)\n' "$pr"

  rollup=$(gh pr view "$pr" --json statusCheckRollup \
    --jq '.statusCheckRollup[]? | (.conclusion // .state // "PENDING")' 2>/dev/null || true)
  if [ -z "$rollup" ]; then
    printf '        checks: none reported\n'
  else
    bad=$(printf '%s\n' "$rollup" | grep -c -E '^(FAILURE|TIMED_OUT|CANCELLED|ACTION_REQUIRED|ERROR)$' || true)
    pending=$(printf '%s\n' "$rollup" | grep -c -E '^(PENDING|IN_PROGRESS|QUEUED|EXPECTED|WAITING)$' || true)
    if [ "$bad" != 0 ]; then
      printf '        checks: %s FAILING — fix-pr before this member merges\n' "$bad"
    elif [ "$pending" != 0 ]; then
      printf '        checks: %s still running — watch-pr before this member merges\n' "$pending"
    else
      printf '        checks: green\n'
    fi
  fi
done

# --- what merges next ------------------------------------------------

section "next"
bottom=$(printf '%s\n' "$chain" | head -1 | cut -f2)
bottom_head=$(printf '%s\n' "$chain" | head -1 | cut -f3)
printf 'merge #%s (%s) first.\n\n' "$bottom" "$bottom_head"
printf 'Only the bottom member merges under a message this toolchain wrote.\n'
printf 'Merging a middle member takes everything below it along, and GitHub\n'
printf 'writes those messages by concatenating commits. Bottom-up is what\n'
printf 'keeps every squash message reviewed and linted.\n'

# The operator's standing answer to the confirmation, granted out of
# band through `mise run preapprove` and keyed on the Claude Code
# session. Absence is the default and the safe one. This is the same
# grant the merge-pr skill reads, and it covers the members of this run
# individually rather than covering the run as a whole.
section "pre-approval"
preapproval=""
if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  preapproval="$(git rev-parse --absolute-git-dir)/preapprovals/$CLAUDE_CODE_SESSION_ID"
fi
if [ -n "$preapproval" ] && grant=$(grep '^merge ' "$preapproval" 2>/dev/null); then
  case ${grant##* } in
  touchid) how="a Touch ID prompt stands behind it" ;;
  *) how="no biometric prompt stood behind it" ;;
  esac
  printf 'merge: GRANTED, %s\n' "$how"
  printf 'Each member still gets its message printed; none gets a question.\n'
else
  printf 'merge: not granted — every member confirms with the operator\n'
fi

section "preconditions"
if [ -f .claude/skills/merge-pr/SKILL.md ]; then
  printf 'merge-pr skill deployed: yes\n'
else
  printf 'merge-pr skill deployed: NO — this skill is an orchestrator over it\n'
fi
if [ -f .claude/skills/review-squash-message/SKILL.md ]; then
  printf 'review-squash-message skill deployed: yes\n'
else
  printf 'review-squash-message skill deployed: NO — run apm install\n'
fi
if git check-ignore --quiet "$DRAFT" 2>/dev/null; then
  printf '%s gitignored: yes\n' "$DRAFT"
else
  printf '%s gitignored: NO — add it to .gitignore before drafting\n' "$DRAFT"
fi
if command -v mise >/dev/null 2>&1 && mise task info lint-squash-msg >/dev/null 2>&1; then
  printf 'mise run lint-squash-msg: present\n'
else
  printf 'mise run lint-squash-msg: ABSENT — stop and tell the operator\n'
fi
