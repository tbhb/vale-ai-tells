#!/usr/bin/env bash
set -euo pipefail
export DEVTOOLS_UNATTENDED=1
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$here/../../merge-pr/scripts/lint-squash-msg.sh" "$@"
