#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # generated beside this entry point
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck disable=SC1091 # generated beside this entry point
. "$DT_LIB_DIR/description.sh"
# shellcheck disable=SC1091 # generated beside this entry point
. "$DT_LIB_DIR/pr-agent.sh"
[ "$#" -eq 0 ] || dt_die "usage: check.sh"
root=$(dt_root)
cd "$root"
pr_checks PR_AGENTDESC.md false
