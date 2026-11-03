#!/usr/bin/env bash
set -euo pipefail
export DEVTOOLS_UNATTENDED=1
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case ${1:-} in
"" | *[!0-9]*) ;;
*)
  if [ "$#" -eq 2 ]; then set -- "$1" "--expected-head=$2"; fi
  ;;
esac
exec bash "$here/../../merge-pr/scripts/squash-merge.sh" "$@"
