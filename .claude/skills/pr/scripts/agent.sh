#!/usr/bin/env bash
# Shared unattended policy. Loaded by lib.sh, never sourced from a repository.

# Only repository behavior belongs here. Authorities still use dt_conf.
dt_repo_conf() {
  if [ "$_DEVTOOLS_AGENTREPO_CONFIG" = true ]; then
    "$_DEVTOOLS_AGENTREPO_BIN" config repository -- "$@"
    return $?
  fi
  # #321 removes this fallback when config is in the minimum agentrepo version
  # on every host and in every consumer.
  local root file value
  root=$(dt_root) || return $?
  file=$root/.agents/agent-skills.conf
  if [ -e "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || dt_die "Repository configuration must be a regular file: $file"
    awk '
      /^[ \t]*(#|$)/ { next }
      {
        key = $0
        sub(/=.*/, "", key)
        gsub(/^[ \t]+|[ \t]+$/, "", key)
        if (!index($0, "=") || seen[key]++ ||
            key !~ /^(lint_commit_cmd|required_hooks|hook_marker|review_max_rounds|pr_template|lint_pr_cmd|pr_log_entry|pr_related_pattern|pr_title_check_cmd|owner_paths|mail_cmd|mail_to|mail_from|lint_squash_cmd|owner_review_label|ruleset_dir|golden_paths|constitutional_paths|loosening_markers|gate_config_paths|disposable_ignored|merge_ready_cmd)$/) {
          print "Invalid or duplicate repository setting: " key > "/dev/stderr"
          bad = 1
        }
      }
      END { exit bad ? 1 : 0 }
    ' "$file" || return 1
    if value=$(_dt_conf_file "$file" "$1"); then
      printf '%s\n' "$value"
      return 0
    fi
  fi
  printf '%s\n' "${2:-}"
}

# Publishers and mergers reserve the same label, including its default.
dt_owner_review_label() {
  local label
  label=$(dt_repo_conf owner_review_label owner-review) || return $?
  [ -n "$label" ] || dt_die "owner_review_label must not be empty"
  printf '%s\n' "$label"
}

dt_agent_context() {
  local dir marker
  dir=$(dt_git_dir) || return $?
  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    [ ! -e "$dir/$marker" ] || dt_die "HELD: $marker is in progress; finish or abort it first."
  done
  gitr symbolic-ref --quiet HEAD >/dev/null || dt_die "HELD: HEAD is detached."
  gitr rev-parse --verify --quiet HEAD >/dev/null || dt_die "Create the initial commit through the interactive commit skill first."
}

# Persistent bounds count findings only for one review subject.
dt_agent_rounds() {
  local state subject rounds max stored_subject
  state=$(dt_state_dir) || return $?
  subject=$2
  max=$(dt_repo_conf review_max_rounds 3) || return $?
  case $max in
  [1-9]) ;;
  *) dt_die "review_max_rounds must be an integer from 1 to 9" ;;
  esac
  rounds=0
  if [ -f "$state/$1.rounds" ]; then
    stored_subject=$(sed -n 's/^subject //p' "$state/$1.rounds") || return $?
    if [ "$stored_subject" = "$subject" ]; then
      cat "$state/$1.rounds"
      rounds=$(awk 'BEGIN { n=0 } /^rounds / { n=$2 } /^finding / { n++ } /^redesign / { n=0 } END { print n }' "$state/$1.rounds") || return $?
      if grep -q '^redesign ' "$state/$1.rounds" && grep -Fqx "finding ${4:-}" "$state/$1.rounds"; then
        printf 'BLOCKED: redesign draft matches a rejected digest for this subject. Rewrite it.\n' >&2
        return 3
      fi
    fi
  fi
  case $rounds in
  [0-9]) ;;
  *) rounds=$max ;;
  esac
  if [ "${3:-check}" = finding ]; then
    if [ "${stored_subject:-}" != "$subject" ]; then
      printf 'subject %s\nbound %s\n' "$subject" "$max" >"$state/$1.rounds"
    fi
    rounds=$((rounds + 1))
    printf 'finding %s\n' "$4" >>"$state/$1.rounds"
  fi
  if [ "$rounds" -ge "$max" ]; then
    if grep -q '^redesign ' "$state/$1.rounds"; then
      printf 'BLOCKED: review reached the finding bound after redesign; inspection required.\n' >&2
    else
      printf 'BLOCKED: review reached the bound of %s finding rounds. Start a redesign with agentrepo review redesign %s --reason TEXT.\n' "$max" "$1" >&2
    fi
    return 3
  fi
}

# Use the same gate cache, with the configured command in its cache key.
dt_commit_lint() {
  local cmd
  if [ "${DEVTOOLS_UNATTENDED:-0}" = 1 ]; then
    cmd=$(dt_repo_conf lint_commit_cmd 'mise run lint-commit-msg') || return $?
    [ -n "$cmd" ] || dt_die "lint_commit_cmd must not be empty"
    dt_gate lint-commit-msg "$1" "$2" bash -c "$cmd"
  else
    dt_gate lint-commit-msg "$1" "$2" mise run lint-commit-msg
  fi
}

# Bind behavior to the review so changed configuration needs a fresh review.
dt_repo_digest() {
  local root
  root=$(dt_root) || return $?
  if [ -e "$root/.agents/agent-skills.conf" ]; then
    dt_digest "$root/.agents/agent-skills.conf"
  else
    printf 'none\n'
  fi
}

# Shared optional reporting transport. Delivery never retries the protected write.
dt_agent_report() {
  local kind=$1 pr=$2 text=$3 cmd to from
  cmd=$(dt_repo_conf mail_cmd) || return $?
  to=$(dt_repo_conf mail_to) || return $?
  from=$(dt_repo_conf mail_from) || return $?
  if [ -n "$cmd" ] && [ -n "$to" ]; then
    cmd=$(dt_path "$cmd") || return $?
    set -- send --to "$to" --kind "$kind" --body "$text" --pr "$pr"
    [ -z "$from" ] || set -- "$@" --from "$from"
    if ! "$cmd" "$@"; then printf 'REPORT NOT SENT: %s\n' "$text" >&2; fi
  else
    printf 'REPORT (%s): %s\n' "$kind" "$text"
  fi
}
