#!/usr/bin/env bash
# Unattended policy used by the shared PR entry points.
# shellcheck disable=SC2034,SC2154 # state is supplied by the shared publisher
export LC_ALL=C
set -o pipefail
# shellcheck disable=SC1091 # generated beside this helper
. "$DT_LIB_DIR/pr-checks.sh"

pr_agent_context() {
  [ "${DEVTOOLS_UNATTENDED:-0}" = 1 ] || return 0
  dt_agent_context || return $?
  local dirty template mode
  dirty=$(gitr status --porcelain --untracked-files=all) || return $?
  [ -z "$dirty" ] || dt_die "Commit the work first; unattended publication requires a clean tree."
  local login
  login=$(dt_conf gh_login) || return $?
  [ -n "$login" ] || dt_die "gh_login must be configured on the machine"
  template=$(pr_template) || return $?
  mode=$(gitr ls-tree HEAD -- "$template" | cut -d' ' -f1) || return $?
  case $mode in 100644 | 100755) ;;
  *) dt_die "The PR template must be a committed regular file." ;;
  esac
}

pr_agent_range() {
  [ "${DEVTOOLS_UNATTENDED:-0}" = 1 ] || return 0
  local count current base_branch
  current=$(gitr symbolic-ref --short HEAD) || return $?
  base_branch=${1#refs/remotes/}
  base_branch=${base_branch#refs/heads/}
  base_branch=${base_branch#origin/}
  [ "$current" != "$base_branch" ] || dt_die "Publish a topic branch, not the base branch."
  count=$(gitr rev-list --count "$1..HEAD") || return $?
  [ "$count" -gt 0 ] || dt_die "No commits to publish; commit the work first."
}

pr_agent_current() {
  [ "${DEVTOOLS_UNATTENDED:-0}" = 1 ] || return 0
  pr_agent_context || return $?
  local current
  current=$(gitr symbolic-ref --short HEAD) || return $?
  [ "$current" = "$1" ] || dt_die "The branch changed during publication; review again."
}

# Checks run through the existing gate cache, including the command value.
pr_checks() {
  local draft=$1 rerun=$2 cmd
  bash "$DT_LIB_DIR/validate-description.sh" "$draft" || return $?
  if [ "${DEVTOOLS_UNATTENDED:-0}" != 1 ]; then
    dt_gate lint-pr-description "$draft" "$rerun" mise run lint-pr-description
    return $?
  fi
  pr_agent_context || return $?
  cmd=$(dt_repo_conf lint_pr_cmd 'mise run lint-pr-description') || return $?
  [ -n "$cmd" ] || dt_die "lint_pr_cmd must not be empty"
  dt_gate lint-pr-description "$draft" "$rerun" bash -c "$cmd" || return $?
  pr_description_policy "$draft" || return $?
  cmd=$(dt_repo_conf pr_title_check_cmd) || return $?
  if [ -n "$cmd" ]; then
    local base title
    base=$(pr_field "$draft" base) || return $?
    base=$(pr_base_ref "$base") || return $?
    title=$(pr_title "$draft") || return $?
    AS_BASE=$base AS_HEAD=HEAD AS_TITLE=$title bash -c "$cmd" || return $?
  fi
}

# The checker receives a restrictive signal for any matching path on the branch.
pr_agent_owner_paths() {
  pr_owner=false
  [ "${DEVTOOLS_UNATTENDED:-0}" = 1 ] || return 0
  local patterns mergebase changed status=0
  patterns=$(dt_repo_conf owner_paths) || return $?
  [ -n "$patterns" ] || return 0
  mergebase=$(gitr merge-base "$base_ref" HEAD) || return $?
  gitr diff --no-ext-diff --no-textconv --no-renames --name-only -z "$mergebase" HEAD >"$state/pr.paths" || return $?
  # shellcheck disable=SC2319 # regex status 2 means invalid syntax, distinct from no match
  [[ '' =~ $patterns ]] || status=$?
  [ "$status" -le 1 ] || dt_die "Invalid owner_paths regular expression"
  while IFS= read -r -d '' changed; do
    if [[ $changed =~ $patterns ]]; then pr_owner=true; fi
  done <"$state/pr.paths"
}

# Publication succeeded before reporting. A transport failure never retries it.
pr_agent_report() {
  [ "${DEVTOOLS_UNATTENDED:-0}" = 1 ] || return 0
  local result number url text
  result=$(dt_gh pr list --head "$branch" --state open --json number,url --jq '.[0] | [.number,.url] | @tsv') || return $?
  IFS=$'\t' read -r number url <<<"$result"
  [[ $number =~ ^[0-9]+$ ]] && [ -n "$url" ] || dt_die "Published, but the PR result is unreadable. Inspect GitHub before retrying."
  text="#$number $title: head $head on base $base; draft=$is_draft; push=$push_kind."
  jq -n --argjson number "$number" --arg url "$url" --arg head "$head" \
    --arg base "$base" --argjson draft "$is_draft" --arg push "$push_kind" \
    '{number:$number,url:$url,head:$head,base:$base,draft:$draft,push:$push}' >"$state/pr.result.json" || return $?
  dt_agent_report fixed "$number" "$text" || return $?
  dt_clear pr
  printf 'published: %s at %s (draft=%s)\n' "$url" "$head" "$is_draft"
}
