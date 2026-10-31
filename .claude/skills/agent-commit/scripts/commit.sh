#!/usr/bin/env bash
# Use the shared commit workflow with unattended confirmation.
set -euo pipefail
export DEVTOOLS_UNATTENDED=1
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$here/../../commit/scripts/commit.sh" "$@"
