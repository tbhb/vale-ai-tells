#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # state is shared with the sourcing publisher
export LC_ALL=C
export GH_PAGER=cat
export GH_PROMPT_DISABLED=1
export PYTHONUTF8=1
unset CDPATH GH_REPO GH_HOST GREP_OPTIONS
IFS=$' \t\n'
# Publication after all gates; sourced by create-pr.sh.
# --- the push, planned -----------------------------------------------
#
# plan_push reads what origin holds now, from origin itself rather than
# from a remote-tracking ref that may be stale, and sets `was` and
# `push_kind`: new, current, fast-forward, or rewrite. It refuses a push
# that is neither a fast-forward nor a rewrite --rewrite allows.

plan_push() {
  remote_refs=$(git ls-remote origin "refs/heads/$branch") ||
    die "could not read ${branch} from origin; nothing was pushed."
  was=$(printf '%s\n' "$remote_refs" | cut -f1) || return $?
  if [ -z "$was" ]; then
    push_kind=new
  elif [ "$was" = "$head" ]; then
    push_kind=current
  elif gitr merge-base --is-ancestor "$was" "$head" 2>/dev/null; then
    push_kind=fast-forward
  elif ! gitr cat-file -e "$was^{commit}" 2>/dev/null; then
    die "origin has ${branch} at ${was}, a commit this checkout never fetched.
Nothing was pushed. Fetch it and look at what arrived before publishing."
  elif gitr merge-base --is-ancestor "$head" "$was"; then
    die "HEAD is behind origin's ${branch} at ${was}, and pushing would drop its
commits. Nothing was pushed. Bring them in first."
  elif [ "$rewrite" = true ]; then
    push_kind=rewrite
  elif [ "$dry_run" = true ]; then
    push_kind=non-fast-forward
  else
    die "origin has ${branch} at ${was}, which HEAD does not contain, so the push
is not a fast-forward and nothing was pushed. Where the branch was rebased
on purpose, run this again with --rewrite on the operator's word: it
replaces only that exact commit. Otherwise merge the base or the remote
commits into the branch rather than rebasing it."
  fi
}

step "planning the push"
plan_push
case $push_kind in
new) printf 'origin has no %s yet; the push creates it\n' "$branch" ;;
current) printf 'origin already has %s at %s\n' "$branch" "$head" ;;
fast-forward) printf 'fast-forward from %s\n' "$was" ;;
rewrite) printf 'REWRITE: replaces origin %s at %s, leasing on that exact commit\n' "$branch" "$was" ;;
non-fast-forward)
  printf 'WARNING: origin has %s at %s, which HEAD does not contain. The real run\n' "$branch" "$was"
  printf 'refuses this push unless --rewrite is passed on the operator'"'"'s word.\n'
  ;;
esac

# gh acts as whoever is signed in. A grant to publish says nothing about
# whose account it publishes under, so before any write the signed-in
# login has to be the configured agent account. gh_login is machine-level
# configuration, never a repository file.

if [ "$dry_run" = true ]; then
  step "dry run"
  check_identity
  printf 'dry run: nothing confirmed, pushed, or published\n'
  rm -f "$copy" "$body_file"
  exit 0
fi

# --- confirmation ----------------------------------------------------

step "confirming"
status=0
pr_agent_context
set --
pr_agent_owner_paths
if [ "$pr_owner" = true ]; then set -- --owner-path; fi
dt_confirm pr "$confirmed" "$@" || status=$?
case $status in
0) ;;
1) exit 1 ;;
*) exit "$DT_HELD" ;;
esac

# The confirmation may have run another program. Check the stamp again,
# then the copy against it, and only then write anything.
require_reviewed
pr_agent_current "$branch"
copy_digest=$(dt_digest "$copy") || exit $?
reviewed_digest=$(dt_stamp_value pr draft) || exit $?
[ "$copy_digest" = "$reviewed_digest" ] ||
  die "the copy of PR_AGENTDESC.md no longer matches the review stamp. Review it again."
check_identity

# --- push ------------------------------------------------------------

step "pushing ${branch}"
plan_push
case $push_kind in
current) printf 'nothing to push\n' ;;
rewrite)
  git push --set-upstream --force-with-lease="refs/heads/$branch:$was" origin "HEAD:refs/heads/$branch" ||
    die "the rewrite push failed; origin may have moved past ${was}. Nothing was published."
  printf 'REWRITE: %s on origin went from %s to %s\n' "$branch" "$was" "$head"
  ;;
*)
  git push --set-upstream origin "HEAD:refs/heads/$branch" ||
    die "git push failed; nothing was published."
  ;;
esac

# A pre-push hook, or a server that rewrites a ref, could leave something
# other than the reviewed commit on the branch.
current_head=$(dt_head) || exit $?
[ "$current_head" = "$head" ] ||
  die "HEAD moved during the push. No pull request was touched; review again."
remote_refs=$(git ls-remote origin "refs/heads/$branch") || exit $?
remote=$(printf '%s\n' "$remote_refs" | cut -f1) || exit $?
[ "$remote" = "$head" ] ||
  die "origin has ${remote:-no ${branch}} after the push, not the reviewed ${head}. No pull request was touched."

# --- publish ---------------------------------------------------------

pr_agent_current "$branch"
if [ "${DEVTOOLS_UNATTENDED:-0}" = 1 ]; then
  require_reviewed
  check_identity
fi

open_number=$(dt_gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty') || exit $?

if [ -n "$open_number" ]; then
  step "updating pull request #${open_number}"
  current=$(dt_gh pr view "$open_number" \
    --json baseRefName,isDraft,labels,reviewRequests,assignees,milestone)
  dt_gh_post pr edit "$open_number" --base "$base" --title "$title" --body-file "$body_file" >/dev/null

  # reconcile <add-flag> <remove-flag> <desired> <current>: bring one
  # property set to what the draft says, removals included.
  reconcile() {
    local item label_identity
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      if [ "$2" = --remove-label ]; then
        label_identity=$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]')
        if [ "$label_identity" = "$owner_review_label" ]; then continue; fi
      fi
      printf '%s\n' "$3" | grep -qxF -- "$item" ||
        dt_gh_post pr edit "$open_number" "$2" "$item" </dev/null >/dev/null
    done <<EOF
$4
EOF
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      printf '%s\n' "$4" | grep -qxF -- "$item" ||
        dt_gh_post pr edit "$open_number" "$1" "$item" </dev/null >/dev/null
    done <<EOF
$3
EOF
  }

  owner_review_label=$(dt_owner_review_label) || exit $?
  owner_review_label=$(printf '%s' "$owner_review_label" | tr '[:upper:]' '[:lower:]')
  current_labels=$(printf '%s' "$current" | jq -r '.labels[].name') || exit $?
  reconcile --add-label --remove-label "$labels" "$current_labels"
  current_reviewers=$(printf '%s' "$current" | jq -r '.reviewRequests[].login // empty') || exit $?
  reconcile --add-reviewer --remove-reviewer "$reviewers" "$current_reviewers"
  current_assignees=$(printf '%s' "$current" | jq -r '.assignees[].login') || exit $?
  reconcile --add-assignee --remove-assignee "$assignees" "$current_assignees"

  current_milestone=$(printf '%s' "$current" | jq -r '.milestone.title // empty') || exit $?
  if [ -n "$milestone" ]; then
    dt_gh_post pr edit "$open_number" --milestone "$milestone" </dev/null >/dev/null
  elif [ -n "$current_milestone" ]; then
    dt_gh_post pr edit "$open_number" --remove-milestone </dev/null >/dev/null
  fi
  current_draft=$(printf '%s' "$current" | jq -r '.isDraft')
  if [ "$is_draft" = true ] && [ "$current_draft" = false ]; then
    dt_gh pr ready "$open_number" --undo >/dev/null
  elif [ "$is_draft" = false ] && [ "$current_draft" = true ]; then
    dt_gh pr ready "$open_number" >/dev/null
  fi
  dt_gh pr view "$open_number" --json url --jq '.url'
  rm -f "$copy" "$body_file"
  step "done"
  printf 'description updated at %s. PR_AGENTDESC.md stays for the next edit.\n' "$head"
  pr_agent_report
  exit 0
fi

step "opening the pull request"
set -- --base "$base" --head "$branch" --title "$title" --body-file "$body_file"
if [ "$is_draft" = true ]; then
  set -- "$@" --draft
fi
while IFS= read -r item; do
  [ -n "$item" ] || continue
  set -- "$@" --label "$item"
done <<EOF
$labels
EOF
while IFS= read -r item; do
  [ -n "$item" ] || continue
  set -- "$@" --reviewer "$item"
done <<EOF
$reviewers
EOF
while IFS= read -r item; do
  [ -n "$item" ] || continue
  set -- "$@" --assignee "$item"
done <<EOF
$assignees
EOF
if [ -n "$milestone" ]; then
  set -- "$@" --milestone "$milestone"
fi

dt_gh_post pr create "$@" || exit $?
rm -f "$copy" "$body_file"

step "done"
printf 'pull request open at %s. PR_AGENTDESC.md stays until merge-pr lands the branch.\n' "$head"

pr_agent_report
