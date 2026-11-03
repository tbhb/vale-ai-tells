#!/usr/bin/env bash
# worktree-ready — detect setup that must precede skill gates without
# changing trust or downloading worktree-local dependencies.
set -euo pipefail

export LC_ALL=C
unset CDPATH GREP_OPTIONS
IFS=$' \t\n'

root=$(git rev-parse --show-toplevel)
cd "$root"

if [ -f mise.toml ] || [ -f .mise.toml ]; then
  if command -v mise >/dev/null 2>&1; then
    if trust=$(mise -C "$root" trust --show 2>&1); then
      case $trust in
      *": untrusted"*)
        printf 'worktree setup: mise config is untrusted. Run:\n\n  mise trust\n' >&2
        exit 1
        ;;
      esac
    else
      printf 'worktree setup: could not check mise trust:\n%s\n' "$trust" >&2
      exit 1
    fi
  fi
fi

[ -f .vale.ini ] || exit 0
command -v vale >/dev/null 2>&1 || exit 0
vale_status=0
vale_output=$(printf 'Worktree setup probe.\n' |
  vale --ext=.md --output=JSON 2>&1) || vale_status=$?
[ "$vale_status" -lt 2 ] && exit 0
case $vale_output in
*"isn't on the StylesPath"* | *"StylesPath '"*"doesn't exist"*)
  printf 'worktree setup: Vale styles are missing. Run:\n\n  mise run devtools:worktree-setup\n' >&2
  exit 1
  ;;
esac
printf 'worktree setup: Vale could not load the repository configuration:\n%s\n' "$vale_output" >&2
exit 1
