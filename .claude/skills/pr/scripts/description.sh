#!/usr/bin/env bash
# description — the readers every pr script shares for PR_AGENTDESC.md
# and for the base it names.
#
# validate-description.sh, review.sh, and create-pr.sh each read the
# draft's frontmatter, and each compares the branch against its base.
# Reading both here is what keeps the validator and the publisher
# agreeing about what a value means, and keeps the validator, the
# reviewer, and the publisher comparing against the same commit.
#
# Sourced, never run. Written for bash 3.2. It runs git for nothing it
# parses, so it needs neither gitr nor lib.sh.

# Every caller sets this already; it stays here too so the hygiene gate
# can see it in the file that calls git.
export LC_ALL=C

# pr_scalar <raw>: a frontmatter scalar as this workflow reads it. A
# matched pair of quotes comes off. YAML's unquoted null spellings, null
# and ~, read as absent, the same as an empty value, so `milestone: null`
# and `milestone: ""` both mean no milestone rather than one by that
# name. A quoted "null" stays the word.
pr_scalar() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case $value in
  null | Null | NULL | '~') value="" ;;
  \"*\" | \'*\')
    if [ "${#value}" -ge 2 ]; then
      value=${value#?}
      value=${value%?}
    fi
    ;;
  esac
  printf '%s' "$value"
}

# pr_fm_end <draft>: the line of the frontmatter's closing ---, or
# nothing when the draft opens without frontmatter.
pr_fm_end() {
  awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { print NR; exit }' "$1"
}

# pr_field <draft> <key>: the value of one frontmatter key, through
# pr_scalar.
pr_field() {
  local end raw
  end=$(pr_fm_end "$1")
  [ -n "$end" ] || return 0
  raw=$(awk -v key="$2" -v last="$end" '
    NR >= last { exit }
    index($0, key ":") == 1 { print substr($0, length(key) + 2); exit }
  ' "$1")
  pr_scalar "$raw"
  printf '\n'
}

# pr_sequence <flow-sequence>: one entry per line from a YAML flow
# sequence such as [a, "b c"].
pr_sequence() {
  printf '%s' "$1" | sed 's/^\[//; s/\]$//' | tr ',' '\n' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//' |
    grep -v '^$' || true
}

# pr_title <draft>: the first level 1 heading after the frontmatter.
pr_title() {
  local end
  end=$(pr_fm_end "$1")
  [ -n "$end" ] || return 0
  awk -v end="$end" 'NR > end && /^# / { print substr($0, 3); exit }' "$1"
}

# pr_body <draft>: everything after the title line. GitHub renders the
# title itself, and the frontmatter is this workflow's own bookkeeping,
# so neither belongs in what gets published.
pr_body() {
  local end
  end=$(pr_fm_end "$1")
  [ -n "$end" ] || return 0
  awk -v end="$end" '
    NR <= end { next }
    !titled && /^# / { titled = 1; next }
    titled && (NF || started) { started = 1; print }
  ' "$1"
}

# pr_base_ref <base>: origin's copy of the base branch when one exists,
# else the local branch. A bare name resolves to the local branch, and a
# stale local copy would count commits that already merged as landing.
# Prints nothing when neither exists.
pr_base_ref() {
  if git rev-parse --verify --quiet "refs/remotes/origin/$1" >/dev/null; then
    printf 'origin/%s\n' "$1"
  elif git rev-parse --verify --quiet "refs/heads/$1" >/dev/null; then
    printf '%s\n' "$1"
  fi
}

# One template selection for scaffolding, validation, and review snapshots.
pr_template() {
  local template
  template=$(dt_repo_conf pr_template "${PR_TEMPLATE:-.github/pull_request_template.md}") || return $?
  case $template in
  '' | /* | .. | ../* | */../* | */..) dt_die "pr_template must name a file inside the repository" ;;
  esac
  printf '%s\n' "$template"
}
