#!/usr/bin/env bash
# Repository prose policy; sourced after lib.sh and description.sh.
export LC_ALL=C

pr_description_policy() {
  local draft=$1 log_policy pattern last related count line item part status failed=0
  local parts=()
  log_policy=$(dt_repo_conf pr_log_entry optional) || return $?
  pattern=$(dt_repo_conf pr_related_pattern) || return $?
  case $log_policy in
  optional) ;;
  required)
    last=$(awk 'NF { line=$0 } END { print line }' "$draft") || return $?
    if ! printf '%s\n' "$last" | grep -Eq '^Log entry: \* \*\*[^*]+\*\*: .+$'; then
      printf 'The description must end with Log entry: * **Label**: text\n'
      failed=1
    fi
    ;;
  *) dt_die "pr_log_entry must be required or optional" ;;
  esac
  if [ -n "$pattern" ]; then
    status=0
    grep -E -- "$pattern" </dev/null >/dev/null || status=$?
    [ "$status" -le 1 ] || dt_die "Invalid pr_related_pattern"
    related=$(awk '
      /^## Related[[:space:]]*$/ { inside=1; next }
      inside && (/^## / || /^Log entry:/) { exit }
      inside && NF { print }
    ' "$draft") || return $?
    count=$(printf '%s\n' "$related" | grep -c . || true)
    if [ "$count" -eq 0 ]; then
      printf 'Related must contain configured items or None\n'
      failed=1
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      item=${line#"${line%%[![:space:]]*}"}
      case $item in '* '* | '- '*) item=${item#??} ;; esac
      item=${item#"${item%%[![:space:]]*}"}
      item=${item%"${item##*[![:space:]]}"}
      case $item in None | None.) [ "$count" -ne 1 ] || continue ;; esac
      IFS=',' read -r -a parts <<<"$item"
      for part in "${parts[@]}"; do
        part=${part#"${part%%[![:space:]]*}"}
        part=${part%"${part##*[![:space:]]}"}
        if ! printf '%s\n' "$part" | grep -Eq -- "$pattern"; then
          printf 'Related contains an invalid item\n'
          failed=1
        fi
      done
    done <<<"$related"
  fi
  return "$failed"
}
