#!/usr/bin/env bash
set -euo pipefail
export DEVTOOLS_UNATTENDED=1
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$here/../../pr/scripts/create-pr.sh" "$@"
