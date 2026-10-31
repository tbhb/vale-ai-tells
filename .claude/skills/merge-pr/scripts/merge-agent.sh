#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # state comes from the sourcing merge scripts
# Unattended merge policy shared by the interactive merge entry points.
export LC_ALL=C GH_PAGER=cat GH_PROMPT_DISABLED=1 PYTHONUTF8=1
unset CDPATH GH_REPO GH_HOST GREP_OPTIONS
IFS=$' \t\n'
set -o pipefail

# Every snapshot passed to ma_gates must request this complete set. The gate
# reads some fields directly and the rest through ma_approved and agentrepo.
readonly MA_GATE_FIELDS=state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,labels,reviews,statusCheckRollup

# Only an explicit operator confirmation may bypass the unattended gates.
# Preflight and review retain their attended behavior until execution selects it.
ma_require_gates() {
  [ "${DEVTOOLS_UNATTENDED:-0}" = 1 ] || [ "${MA_REQUIRE_GATES:-false}" = true ]
}

ma_context() {
  ma_require_gates || return 0
  dt_agent_context || return $?
  local dirty login
  dirty=$(gitr status --porcelain --untracked-files=all) || return $?
  [ -z "$dirty" ] || dt_die "Commit the work first; unattended merging requires a clean tree."
  login=$(dt_conf gh_login) || return $?
  [ -n "$login" ] || dt_die "gh_login must be configured on the machine"
  command -v uv >/dev/null || dt_die "uv is required for the YAML policy reader"
  [ -n "$_DEVTOOLS_AGENTREPO_BIN" ] || dt_die "agentrepo is required for check judgement"
  "$_DEVTOOLS_AGENTREPO_BIN" --help >/dev/null 2>&1 || dt_die "a working agentrepo is required for check judgement"
}

ma_lint() {
  local head=$1 cmd config tmp status
  local -a lint_env=(env -u DEVTOOLS_CSPELL_CONFIG)
  mp_fetch_commit "$head" || return $?
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/devtools-squash-cspell.XXXXXX") || return $?
  config=$tmp/.cspell.jsonc
  if gitr cat-file -e "$head:.cspell.jsonc" 2>/dev/null; then
    if ! gitr show "$head:.cspell.jsonc" >"$config"; then
      rm -rf -- "$tmp"
      dt_die "Could not read .cspell.jsonc from the pull request head."
      return 1
    fi
    lint_env=(env DEVTOOLS_CSPELL_CONFIG="$config")
  fi
  if gitr cat-file -e "$head:.cspell-words.txt" 2>/dev/null; then
    if ! gitr show "$head:.cspell-words.txt" >"$tmp/.cspell-words.txt"; then
      rm -rf -- "$tmp"
      dt_die "Could not read .cspell-words.txt from the pull request head."
      return 1
    fi
  fi
  status=0
  if [ "${DEVTOOLS_UNATTENDED:-0}" = 1 ]; then
    cmd=$(dt_repo_conf lint_squash_cmd 'mise run lint-squash-msg') || status=$?
    if [ "$status" -eq 0 ] && [ -z "$cmd" ]; then
      rm -rf -- "$tmp"
      dt_die "lint_squash_cmd must not be empty"
      return 1
    fi
    if [ "$status" -eq 0 ]; then
      "${lint_env[@]}" bash -c "$cmd" || status=$?
    fi
  else
    "${lint_env[@]}" mise run lint-squash-msg || status=$?
  fi
  rm -rf -- "$tmp"
  return "$status"
}

ma_policy() { uv run --quiet --script "$DT_LIB_DIR/merge-policy.py" "$@"; }

# gh pr view omits author.__typename; read all review pages explicitly.
ma_reviews() {
  local number=$1 view=$2 head
  head=$(mp_field "$view" headRefOid) || return $?
  dt_gh_repo "query(\$owner:String!,\$name:String!,\$number:Int!,\$endCursor:String){repository(owner:\$owner,name:\$name){pullRequest(number:\$number){headRefOid reviews(first:100,after:\$endCursor){nodes{author{__typename login} state submittedAt body lastEditedAt commit{oid}} pageInfo{hasNextPage endCursor}}}}}" \
    -F "number=$number" --paginate --slurp >"$view.reviews" || return $?
  jq -e --arg head "$head" --slurpfile pages "$view.reviews" '
    if ($pages[0] | length > 0 and all(.[]; .data.repository.pullRequest.headRefOid == $head)) then
      .reviews = [$pages[0][].data.repository.pullRequest.reviews.nodes[]]
    else error("PR head changed while reading review authors") end
  ' "$view" >"$view.next" || return $?
  mv "$view.next" "$view" || return $?
  rm -f -- "$view.reviews"
}

# Machine authorities use GraphQL logins, not the REST Bot suffix.
ma_login() {
  local key=$1 login
  login=$(dt_conf "$key") || return $?
  case $login in
  *'[bot]') dt_die "$key must use the GraphQL login ${login%\[bot\]}, without [bot]" ;;
  esac
  printf '%s\n' "$login"
}

# Latest decisive review, on the exact head, from machine-selected authority.
ma_approved() {
  [ -n "$2" ] || return 1
  jq -e --arg login "$2" --arg head "$3" --arg type "${4:-}" '
    [.reviews[] | select(.author.login == $login) |
      select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")]
    | sort_by(.submittedAt) | last | .state == "APPROVED" and .commit.oid == $head
      and ($type == "" or .author.__typename == $type)
  ' "$1" >/dev/null
}

ma_identity() {
  local want actual
  want=$(dt_conf gh_login) || return $?
  [ -n "$want" ] || dt_die "gh_login must be configured on the machine"
  actual=$(dt_gh_login) || return $?
  [ "$want" = "$actual" ] || dt_die "gh is signed in as $actual, not $want"
}

# Reused before review and again immediately before every merge write.
ma_gates() {
  ma_require_gates || return 0
  local view=$1 pr=$2 base_oid=$3 final=${4:-false} head base reviewer reviewer_type label ready config key value required default dir st root encoded merge_base
  ma_context || return $?
  st=$(dt_state_dir) || return $?
  root=$(dt_root) || return $?
  head=$(mp_field "$view" headRefOid) || return $?
  base=$(mp_field "$view" baseRefName) || return $?
  jq -e ' .state == "OPEN" and .isDraft == false and .mergeable == "MERGEABLE" and .mergeStateStatus == "CLEAN"' "$view" >/dev/null || dt_die "PR is not open, ready, MERGEABLE, and CLEAN"
  ma_identity || return $?
  reviewer=$(ma_login required_reviewer) || return $?
  [ -n "$reviewer" ] || dt_die "required_reviewer must be configured on the machine"
  reviewer_type=$(dt_conf required_reviewer_type) || return $?
  case $reviewer_type in
  '' | Bot | User) ;;
  *) dt_die "required_reviewer_type must be Bot or User when set" ;;
  esac
  ma_approved "$view" "$reviewer" "$head" "$reviewer_type" || dt_die "WAITING_REVIEW: $reviewer must approve the current head"
  label=$(dt_owner_review_label) || return $?
  if jq -e --arg label "$label" '.labels | any(.name == $label)' "$view" >/dev/null; then
    dt_die "needs-owner: the PR has the owner-review label"
  fi
  if [ "$final" != true ]; then
    mp_local_diff "$base_oid" "$head" "$st" || return $?
    config='{}'
    for key in golden_paths loosening_markers gate_config_paths owner_paths disposable_ignored; do
      value=$(dt_repo_conf "$key") || return $?
      config=$(printf '%s' "$config" | jq --arg key "$key" --arg value "$value" '. + {($key):$value}') || return $?
    done
    ma_policy inspect "$base_oid" "$head" <<<"$config" >"$st/merge.policy.json" || return $?
  fi
  if [ "$final" != true ]; then MA_POLICY=$(cat "$st/merge.policy.json") || return $?; fi
  MA_POLICY=$(ma_policy evaluate "$reviewer" "$head" "$view" <<<"$MA_POLICY") || return $?
  MA_OWNER_OVERRIDE=''
  if jq -e '.owner_required' <<<"$MA_POLICY" >/dev/null; then
    jq -r '.findings[] | @json' <<<"$MA_POLICY" >&2
    value=$(ma_login merge_owner) || return $?
    ma_approved "$view" "$value" "$head" || dt_die "needs-owner: golden files or loosened gates require merge_owner approval on the current head"
    MA_OWNER_OVERRIDE=$value
    printf 'owner override: %s approved %s\n' "$value" "$head"
  fi
  if [ "$final" != true ]; then
    dir=$(dt_repo_conf ruleset_dir .github/rulesets) || return $?
    default=$(dt_gh repo view --json defaultBranchRef --jq .defaultBranchRef.name) || return $?
    encoded=$(jq -nr --arg base "$base" '$base|@uri') || return $?
    dt_gh api "repos/{owner}/{repo}/rules/branches/$encoded" >"$st/merge.rules.json" || return $?
    required=$(ma_policy required "$base_oid" "$base" "$default" "$dir" <"$st/merge.rules.json") || return $?
    MA_REQUIRED=$required
  else
    required=$MA_REQUIRED
  fi
  [ -n "$required" ] || dt_die "No required checks are known for the base"
  # A required check that ran on a stale merge ref reports SKIPPED. The hint
  # needs the merge base only to say whether the branch lags; an unreadable
  # merge base reports unknown and never changes the verdict.
  merge_base=$(gitr merge-base "$base_oid" "$head" 2>/dev/null) || merge_base=''
  set -- checks evaluate --file "$view" --expected-head "$head" --pr "$pr" --base "$base_oid" --merge-base "$merge_base"
  while IFS= read -r value; do set -- "$@" --required "$value"; done <<<"$required"
  "$_DEVTOOLS_AGENTREPO_BIN" "$@" || return $?
  ready=$(dt_repo_conf merge_ready_cmd) || return $?
  if [ "$final" != true ] && [ -n "$ready" ]; then
    ready=$(dt_path "$ready") || return $?
    [ -x "$ready" ] || dt_die "merge_ready_cmd must name an executable"
    "$ready" "$root" "$pr" "$head" || return $?
  fi
}

ma_prepare_children() {
  [ "${DEVTOOLS_UNATTENDED:-0}" = 1 ] || return 0
  [ "$cross_repo" = false ] || return 0
  local children child count
  children=$(dt_gh pr list --base "$head_ref" --state open --limit 500 --json number) || return $?
  count=$(printf '%s' "$children" | jq 'length') || return $?
  [ "$count" -lt 500 ] || dt_die "Too many dependent PRs to retarget safely"
  children=$(printf '%s' "$children" | jq -r '.[].number') || return $?
  for child in $children; do
    ma_identity || return $?
    [ "$child" = "$number" ] || dt_gh_post pr edit "$child" --base "$base_ref" </dev/null || return $?
  done
}

# Verify the remote message before deleting any evidence or branch.
ma_verify() {
  [ "${DEVTOOLS_UNATTENDED:-0}" = 1 ] || return 0
  local repository wanted actual live_base
  repository=$(dt_gh repo view --json url --jq .url) || return $?
  live_base=$(mp_base_oid "$base_ref") || return $?
  gitr -c credential.helper= -c 'credential.helper=!gh auth git-credential' fetch --no-tags --no-write-fetch-head "$repository" "$live_base" "$merge_commit" || return $?
  gitr merge-base --is-ancestor "$merge_commit" "$live_base" || dt_die "merged-not-as-reviewed: merge commit is not on the live base"
  wanted=$(git stripspace <"$message") || return $?
  actual=$(gitr cat-file commit "$merge_commit" | sed '1,/^$/d' | git stripspace) || return $?
  [ "$actual" = "$wanted" ] || dt_die "merged-not-as-reviewed: the remote message differs; preserve evidence and inspect"
}

ma_report() {
  [ "${DEVTOOLS_UNATTENDED:-0}" = 1 ] || return 0
  local text owners
  owners=$(jq -c '{owner_paths,owner_rule}' <<<"$MA_POLICY") || return $?
  text=$(jq -r --arg number "$number" --arg commit "$merge_commit" --arg owner "${MA_OWNER_OVERRIDE:-none}" '
    "Merged #\($number) as \($commit). Owner override: \($owner). Owner paths: \(.owner_paths). Owner rule: \(.owner_rule)."' <<<"$owners") || return $?
  jq --arg owner "${MA_OWNER_OVERRIDE:-}" --argjson paths "$owners" '. + {owner_override:$owner} + $paths' "$result" >"$result.next" || return $?
  mv "$result.next" "$result"
  dt_agent_report fixed "$number" "$text" || return $?
  printf '%s\n' "$text"
}

# Holds and uncertain writes report without changing their original status.
ma_exit() {
  local status=$1 text
  [ "${BASH_SUBSHELL:-0}" -eq 0 ] || return "$status"
  trap - EXIT
  [ "$status" -ne 0 ] || return 0
  set +e
  text="Merge workflow for #${number:-unknown} held with status $status. Inspect the preserved draft, review, and merge result before retrying."
  dt_agent_report blocker "${number:-}" "$text" || printf '%s\n' "$text" >&2
  exit "$status"
}
if [ "${DEVTOOLS_UNATTENDED:-0}" = 1 ]; then trap 'ma_exit "$?"' EXIT; fi
