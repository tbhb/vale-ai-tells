#!/usr/bin/env bash
# preflight — gather every fact the rebase-pr-stack skill needs before
# it moves a branch.
#
# The rebase-pr-stack SKILL.md inlines this through the !`...`
# preprocessor. The questions it settles are which branches make up the
# stack, which of them are actually behind, whether the extension that
# performs the cascade can see the stack at all, and whether anything
# in the worktree is in the way.
#
# The chain comes from stack-chain.sh, which reads GitHub rather than
# local tracking. The extension's own tracking is reported separately,
# because the cascade needs it and GitHub's answer does not depend on
# it.
#
# Nothing here mutates anything beyond a fetch. Usage:
#   preflight.sh [number|branch]
set -euo pipefail

# --- environment hardening -------------------------------------------
export LC_ALL=C
export GH_PAGER=cat
export GH_PROMPT_DISABLED=1
export PYTHONUTF8=1
unset CDPATH GH_REPO GH_HOST GREP_OPTIONS
IFS=$' \t\n'

readonly PR_CAP=${STACK_PREFLIGHT_PRS:-100}
readonly FETCH_TIMEOUT=${STACK_PREFLIGHT_FETCH_TIMEOUT:-20}

section() { printf '\n== %s ==\n' "$1"; }
none() { printf '(none)\n'; }

root=$(git rev-parse --show-toplevel)
cd "$root"
git_dir=$(git rev-parse --absolute-git-dir)
here=${BASH_SOURCE%/*}

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

if gh extension list 2>/dev/null | grep -q 'gh stack'; then
  printf 'gh stack extension: present\n'
else
  printf 'gh stack extension: ABSENT — this skill performs the cascade through it.\n'
  printf 'Install it with: gh extension install github/gh-stack\n'
  printf 'Stop here and tell the operator.\n'
  exit 0
fi

# --- anything already in progress ------------------------------------

section "in progress"
blocked=""
if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
  printf 'A rebase is in progress.\n'
  blocked=rebase
elif [ -f "$git_dir/MERGE_HEAD" ]; then
  printf 'A merge is in progress.\n'
  blocked=merge
elif [ -f "$git_dir/CHERRY_PICK_HEAD" ]; then
  printf 'A cherry-pick is in progress.\n'
  blocked=cherry-pick
else
  none
fi
if [ "$blocked" = rebase ]; then
  printf '\nWhere gh stack rebase started it, resolve through the\n'
  printf 'resolve-rebase-conflicts skill and resume the cascade with\n'
  printf 'gh stack rebase --continue. Where something else started it, finish\n'
  printf 'that first.\n'
elif [ -n "$blocked" ]; then
  printf '\nFinish or abandon it before starting a cascade. Nothing here can\n'
  printf 'reason about a stack while the worktree holds a half-applied change.\n'
fi

section "working tree"
dirty=$(git status --porcelain=v1 2>/dev/null || true)
if [ -n "$dirty" ]; then
  printf '%s\n' "$dirty"
  printf '\nThe cascade checks out every branch in the stack in turn, and a dirty\n'
  printf 'tree either blocks that or follows it from branch to branch. Park the\n'
  printf 'work in a throwaway commit first:\n\n'
  printf '  git commit -am wip --no-verify\n\n'
  printf 'That is the one sanctioned --no-verify here, and git reset --soft HEAD~1\n'
  printf 'unwinds it afterwards.\n'
else
  none
fi

branch=$(git rev-parse --abbrev-ref HEAD)
printf '\ncurrent branch: %s\n' "$branch"

# --- the chain -------------------------------------------------------

target=${1:-}
number=""
case $target in
'') ;;
*[!0-9]*) number=$(gh pr list --head "$target" --state open --json number --jq '.[0].number' 2>/dev/null || true) ;;
*) number=$target ;;
esac
if [ -z "$number" ] && [ -z "$target" ]; then
  number=$(gh pr list --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || true)
fi

if [ -z "$number" ]; then
  section "the stack"
  printf 'No pull request resolved from %s, and none given.\n' "${target:-$branch}"
  printf 'Pass a number or a branch as the skill argument.\n\n'
  printf 'open pull requests here:\n'
  gh pr list --state open --limit "$PR_CAP" \
    --json number,headRefName,baseRefName \
    --template '{{range .}}#{{.number}} {{.headRefName}} -> {{.baseRefName}}
{{end}}' 2>/dev/null || none
  exit 0
fi

if command -v timeout >/dev/null 2>&1; then
  timeout "$FETCH_TIMEOUT" git fetch --quiet --prune origin 2>/dev/null || true
else
  git fetch --quiet --prune origin 2>/dev/null || true
fi

chain=$(bash "$here/stack-chain.sh" "$number")

section "the stack"
case $chain in
"ERR	not-open"*)
  printf '#%s is not an open pull request.\n' "$number"
  exit 0
  ;;
"ERR	branching"*)
  printf 'Two open pull requests share the base %s, which is a tree rather\n' "${chain##*$'\t'}"
  printf 'than a stack. Name the top of the limb you mean as the argument.\n'
  exit 0
  ;;
"ERR"*)
  printf 'could not derive the chain: %s\n' "$chain"
  exit 0
  ;;
esac

depth=$(printf '%s\n' "$chain" | grep -c . || true)
trunk=$(printf '%s\n' "$chain" | head -1 | cut -f4)
printf 'depth: %s\ntrunk: %s\n\n' "$depth" "$trunk"
printf '%s\n' "$chain" | awk -F'\t' '{ printf "  %s. #%-5s %s -> %s\n", $1, $2, $3, $4 }'

# --- local tracking --------------------------------------------------
#
# gh stack rebase performs the cascade, and it acts only on a stack it
# tracks. This is reported apart from the chain on purpose: the chain is
# what GitHub knows, and this is what the extension can move.

section "local stack tracking"
if tracked=$(gh stack view --short 2>&1); then
  printf '%s\n' "$tracked"
else
  printf 'not tracked here: %s\n' "$(printf '%s' "$tracked" | head -1)"
  printf '\nThe extension adopts an existing set of branches, bottom first:\n\n'
  printf '  gh stack init'
  printf '%s\n' "$chain" | cut -f3 | while read -r b; do
    [ -n "$b" ] && printf ' %s' "$b"
  done
  printf '\n\nEvery branch it names has to exist locally. The next block says which do.\n'
fi

# --- per-branch state ------------------------------------------------

section "branches"
printf '%s\n' "$chain" | while IFS=$'\t' read -r pos pr head base title; do
  [ -n "$head" ] || continue
  printf '#%s %s\n' "$pr" "$head"

  if git show-ref --verify --quiet "refs/heads/$head"; then
    if git show-ref --verify --quiet "refs/remotes/origin/$head"; then
      counts=$(git rev-list --left-right --count "refs/heads/$head...refs/remotes/origin/$head" 2>/dev/null || true)
      ahead=${counts%%	*}
      behind=${counts##*	}
      if [ "$ahead" != 0 ] && [ "$behind" != 0 ]; then
        printf '      local: DIVERGED from origin (%s ahead, %s behind)\n' "$ahead" "$behind"
      elif [ "$behind" != 0 ]; then
        printf '      local: %s behind origin\n' "$behind"
      elif [ "$ahead" != 0 ]; then
        printf '      local: %s ahead of origin, not pushed\n' "$ahead"
      else
        printf '      local: matches origin\n'
      fi
    else
      printf '      local: exists, nothing on origin\n'
    fi
  else
    printf '      local: ABSENT — gh stack init cannot name it\n'
  fi

  # Whether this member already carries its base. Every member answering
  # yes is what the cascade exists to produce.
  base_ref="refs/remotes/origin/$base"
  head_ref="refs/remotes/origin/$head"
  if git show-ref --verify --quiet "$base_ref" && git show-ref --verify --quiet "$head_ref"; then
    if git merge-base --is-ancestor "$base_ref" "$head_ref" 2>/dev/null; then
      printf '      base:  carries origin/%s\n' "$base"
    else
      printf '      base:  BEHIND origin/%s by %s commit(s) — the cascade moves this\n' \
        "$base" "$(git rev-list --count "$head_ref..$base_ref" 2>/dev/null || echo '?')"
    fi
  else
    printf '      base:  cannot compare (a ref is missing on origin)\n'
  fi
done

section "what this run has to do"
needs=$(printf '%s\n' "$chain" | while IFS=$'\t' read -r pos pr head base title; do
  [ -n "$head" ] || continue
  b="refs/remotes/origin/$base"
  h="refs/remotes/origin/$head"
  git show-ref --verify --quiet "$b" && git show-ref --verify --quiet "$h" || continue
  git merge-base --is-ancestor "$b" "$h" 2>/dev/null || printf '  #%s %s\n' "$pr" "$head"
done)
if [ -z "$needs" ]; then
  printf 'Every member already carries its base on origin, so a cascade would\n'
  printf 'replay nothing. Say so and stop, unless the operator named a reason to\n'
  printf 'run one anyway, such as bringing local copies across after a merge.\n'
else
  printf 'These members do not carry their base, and the cascade moves them:\n\n%s\n' "$needs"
fi
