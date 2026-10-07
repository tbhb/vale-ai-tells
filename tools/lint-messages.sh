#!/usr/bin/env bash
# lint-messages — lint each rule's own message: field with the ai-tells
# style, so the package's diagnostics don't contain the patterns they flag.
#
# Each message is copied into a scratch Markdown file named for its rule
# and vale reads those, never the rule files. Vale 3.24 lints a data
# file's YAML comments whatever a View selects, and the raw-scoped rules
# read the comments too, where IgnoredScopes cannot reach. The comments
# quote the flagged patterns on purpose, so linting the rule files
# themselves fails on text no message contains.
#
# Every rule writes its message as one double-quoted line. A rule that
# doesn't is refused rather than skipped, because a message this script
# cannot extract would otherwise pass without ever reaching vale.
#
# Findings print under FILE: <style>/<Rule>.md, always on line 1, in the
# ai-tells-agent template's shape, and the exit code carries the result.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

status=0
for rule in "$root"/styles/ai-tells*/*.yml; do
  style=$(basename "$(dirname "$rule")")
  name=$(basename "$rule" .yml)
  line=$(grep -m1 '^message: ' "$rule" || true)
  case $line in
    'message: "'*'"') ;;
    *)
      echo "lint-messages: ${style}/${name}.yml has no one-line double-quoted message:" >&2
      status=1
      continue
      ;;
  esac
  mkdir -p "$scratch/$style"
  line=${line#message: \"}
  printf '%s\n' "${line%\"}" > "$scratch/$style/$name.md"
done
[ "$status" -eq 0 ] || exit "$status"

# A config whose sections miss the scratch paths loads no styles, and vale
# then reports nothing, exactly as it does for clean messages. Bad text
# must draw a finding before silence counts as a pass.
cd "$scratch"
if [ -z "$(printf 'We delve into a rich tapestry.\n' | vale --config="$root/.vale-messages.ini" --output=line --path=probe.md 2>&1 || true)" ]; then
  echo "lint-messages: the probe drew no finding, so .vale-messages.ini binds no style to the scratch files" >&2
  exit 1
fi

vale --config="$root/.vale-messages.ini" --output=ai-tells-agent.tmpl ai-tells*
