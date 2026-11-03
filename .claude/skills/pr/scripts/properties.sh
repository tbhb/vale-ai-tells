#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # state is shared with the sourcing publisher
export LC_ALL=C
export GH_PAGER=cat
export GH_PROMPT_DISABLED=1
export PYTHONUTF8=1
unset CDPATH GH_REPO GH_HOST GREP_OPTIONS
IFS=$' \t\n'
# Resolve draft properties before any expensive gates; sourced by create-pr.sh.
copy=$state/pr.draft
cp "$draft" "$copy"
is_draft=$(pr_field "$copy" draft)
labels_field=$(pr_field "$copy" labels) || exit $?
labels=$(pr_sequence "$labels_field") || exit $?
reviewers_field=$(pr_field "$copy" reviewers) || exit $?
reviewers=$(pr_sequence "$reviewers_field") || exit $?
assignees_field=$(pr_field "$copy" assignees) || exit $?
assignees=$(pr_sequence "$assignees_field") || exit $?
milestone=$(pr_field "$copy" milestone)
title=$(pr_title "$copy")
[ -n "$title" ] || die "the draft carries no level 1 heading to use as the title"
body_file=$state/pr.body.md
pr_body "$copy" >"$body_file"
[ -s "$body_file" ] || die "the description has a title but no body"

# --- gate 3: resolve everything the API has to recognize -------------
#
# gh adds labels, reviewers, and the milestone after the pull request
# exists. An unknown one therefore fails *after* creation, leaving a
# published pull request missing the properties it was supposed to
# carry. Resolving them first turns that into a clean refusal.

step "resolving pull request properties"
command -v gh >/dev/null 2>&1 || die "gh is not installed"
dt_gh_login >/dev/null || exit $?

known_labels=$(dt_gh label list --limit 200 --json name --jq '.[].name') || exit $?
while IFS= read -r want; do
  [ -n "$want" ] || continue
  printf '%s\n' "$known_labels" | grep -qxF -- "$want" ||
    die "no label named \"${want}\" in this repository. Preflight printed the label set."
done <<EOF
$labels
EOF

if [ -n "$milestone" ]; then
  known_milestones=$(dt_gh_repo "query(\$owner:String!,\$name:String!){repository(owner:\$owner,name:\$name){milestones(first:100,states:OPEN){nodes{title} pageInfo{hasNextPage}}}}" --jq '.data.repository.milestones | if .pageInfo.hasNextPage then error("more than 100 open milestones") else .nodes[].title end') || exit $?
  printf '%s\n' "$known_milestones" | grep -qxF -- "$milestone" ||
    die "no milestone named \"${milestone}\" in this repository."
fi

# Every issue or pull request the description points at has to exist. A
# reference to a number nobody opened is the cheapest kind of invented
# claim, and it is the one a machine can settle.
refs=$(grep -o '#[0-9][0-9]*' "$body_file" | sort -u | head -20 || true)
for ref in $refs; do
  number=${ref#\#}
  dt_gh_repo "query(\$owner:String!,\$name:String!,\$number:Int!){repository(owner:\$owner,name:\$name){issueOrPullRequest(number:\$number){__typename}}}" -F "number=$number" --jq '.data.repository.issueOrPullRequest | if . == null then error("reference does not exist") else .__typename end' >/dev/null || {
    status=$?
    printf 'could not validate reference #%s\n' "$number" >&2
    exit "$status"
  }
done
printf 'labels, milestone, and references all resolve\n'
