#!/usr/bin/env bash
# pull-request — readers of a pull request's live state, shared by the
# merge-pr scripts that judge it: preflight.sh, review.sh, and
# squash-merge.sh.
#
# Sourced, never run, after lib.sh. Written for bash 3.2. Every reader
# here starts with one `gh pr view --json` response saved to a file.
# Unattended review authors need a separate GraphQL read pinned to that head.

# --- environment hardening -------------------------------------------
# lib.sh and the sourcing script repeat this block; it stays here too so
# the hygiene gate can see it in the file that calls gh.
export LC_ALL=C
export GH_PAGER=cat
export GH_PROMPT_DISABLED=1
export PYTHONUTF8=1
unset CDPATH GH_REPO GH_HOST GREP_OPTIONS

# mp_need_tools: gh, signed in, and jq, or stop.
mp_need_tools() {
  command -v gh >/dev/null 2>&1 || dt_die "gh is not installed"
  dt_gh_login >/dev/null || exit $?
  command -v jq >/dev/null 2>&1 || dt_die "jq is not installed"
}

# mp_view <number> <file> <field,...>: save one response naming every
# field the caller reads.
mp_view() {
  dt_gh pr view "$1" --json "$3" >"$2" || return $?
  if ma_require_gates; then
    case ,$3, in
    *,reviews,*) ma_reviews "$1" "$2" || return $? ;;
    esac
  fi
}

# mp_field <file> <field>: one top-level field of a saved response, a
# boolean as true or false, a missing value as nothing.
mp_field() {
  jq -r --arg f "$2" '.[$f] | if . == null then "" else tostring end' "$1"
}

# mp_base_oid <base-ref>: the commit the base branch points at on
# GitHub, read through gh so it names the same repository gh merges in.
mp_base_oid() {
  dt_gh_repo "query(\$owner:String!,\$name:String!,\$ref:String!){repository(owner:\$owner,name:\$name){ref(qualifiedName:\$ref){target{oid}}}}" -f "ref=refs/heads/$1" --jq '.data.repository.ref.target.oid // error("base ref not found")'
}

# mp_judge_checks <file>: judge the statusCheckRollup in a saved
# response, printing one line a check: a verdict (ok, pending, or fail),
# the state it read, and the check's name, separated by tabs.
#
# The rollup keeps every run GitHub started for the head commit, not
# only the latest. A workflow whose concurrency group cancelled a first
# run when a second began leaves the cancelled jobs in the rollup beside
# the passing ones, and counting those would refuse a green pull
# request. So check runs are grouped by workflow and check name, and the
# one that started last stands for its group. A run that has not started
# has no start time and counts as the latest, so a queued re-run reads
# as pending rather than letting the run it replaces decide. A cancel
# with no later run still fails. Status contexts carry no workflow or
# run history of the same shape, so each one is judged as it stands.
#
#   0  every check ok      1  a check failed      2  a check pending
#   3  the rollup could not be read      4  no checks reported
mp_judge_checks() {
  local out
  out=$(jq -r '
    def is_status: (.__typename // "") == "StatusContext"
      or ((.name // null) == null and (.context // null) != null);
    def started:
      (.startedAt // "") | if . == "" or startswith("0001") then "9999-12-31T23:59:59Z" else . end;
    def state:
      if is_status then ((.state // "PENDING") | ascii_upcase)
      elif ((.status // "COMPLETED") | ascii_upcase) != "COMPLETED" then (.status | ascii_upcase)
      else ((.conclusion // "") | ascii_upcase | if . == "" then "PENDING" else . end)
      end;
    def verdict:
      if test("^(FAILURE|TIMED_OUT|CANCELLED|ACTION_REQUIRED|ERROR|STARTUP_FAILURE|STALE)$") then "fail"
      elif test("^(PENDING|IN_PROGRESS|QUEUED|EXPECTED|WAITING|REQUESTED)$") then "pending"
      else "ok" end;
    def check_name:
      if is_status then .context
      else (((.workflowName // "") | if . == "" then "" else . + " / " end) + (.name // "")) end;
    (.statusCheckRollup // []) as $all
    | ($all | map(select(is_status | not))
        | group_by([(.workflowName // ""), (.name // "")])
        | map(max_by(started))) as $latest
    | ($latest + ($all | map(select(is_status))))[]
    | state as $s
    | [($s | verdict), $s, check_name]
    | @tsv
  ' "$1" 2>/dev/null) || return 3
  [ -n "$out" ] || return 4
  printf '%s\n' "$out"
  printf '%s\n' "$out" | awk -F'\t' '
    $1 == "fail" { failed = 1 }
    $1 == "pending" { pending = 1 }
    END { exit failed ? 1 : (pending ? 2 : 0) }
  '
}

# mp_superseded <file>: how many check runs the judgement left out
# because a later run of the same check replaced them.
mp_superseded() {
  jq -r '
    (.statusCheckRollup // [])
    | map(select((.__typename // "") != "StatusContext" and (.name // null) != null))
    | length - (group_by([(.workflowName // ""), .name]) | length)
  ' "$1"
}

# mp_require_reviews <file> <number>: distinguish waiting on GitHub's
# required approvals from a broken merge. No approval is also valid
# when the repository requires none.
mp_require_reviews() {
  local decision
  decision=$(mp_field "$1" reviewDecision)
  case ${decision:-NONE} in
  APPROVED | NONE) ;;
  REVIEW_REQUIRED | CHANGES_REQUESTED)
    printf 'WAITING_REVIEW: #%s review decision is %s; GitHub still requires an approving review (for example, a code owner). Resolve the review requests, then rerun.\n' "$2" "$decision" >&2
    exit 75
    ;;
  *) dt_die "#$2 has an unknown review decision: $decision" ;;
  esac
}

# mp_local_diff <base-oid> <head-oid> <inputs-dir>: fetch the pinned
# objects from the base repository, including fork PR heads exposed by
# its pull refs. Use gh authentication for private repositories without
# persisting credentials. Do not change branches, the index, or FETCH_HEAD.
mp_local_diff() {
  local repository
  repository=$(dt_gh repo view --json url --jq .url) || exit $?
  [ -n "$repository" ] || dt_die "Could not locate the pull request repository."
  local shallow
  shallow=$(gitr rev-parse --is-shallow-repository) || return $?
  if [ "$shallow" = true ]; then
    gitr -c credential.helper= -c 'credential.helper=!gh auth git-credential' fetch --no-tags --no-write-fetch-head --unshallow "$repository" "$1" "$2" ||
      dt_die "Could not fetch the complete pinned base and head histories."
  else
    gitr -c credential.helper= -c 'credential.helper=!gh auth git-credential' fetch --no-tags --no-write-fetch-head "$repository" "$1" "$2" ||
      dt_die "Could not fetch the pinned base and head."
  fi
  gitr diff --no-ext-diff --no-textconv --no-color --binary --full-index "$1...$2" -- >"$3/change.diff" ||
    dt_die "Could not build the complete pinned diff."
  gitr diff --no-ext-diff --no-textconv --no-color --name-status "$1...$2" -- >"$3/files.txt" ||
    dt_die "Could not list the pinned diff files."
}

# mp_fetch_commit <oid>: make one pinned pull request commit available
# without moving a branch, the index, or FETCH_HEAD.
mp_fetch_commit() {
  gitr cat-file -e "$1^{commit}" 2>/dev/null && return 0
  local repository
  repository=$(dt_gh repo view --json url --jq .url) || return $?
  [ -n "$repository" ] || dt_die "Could not locate the pull request repository."
  gitr -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
    fetch --no-tags --no-write-fetch-head "$repository" "$1" ||
    dt_die "Could not fetch the pinned pull request head."
}

# shellcheck disable=SC1091 # generated beside this reader
. "$DT_LIB_DIR/merge-agent.sh"
