#!/usr/bin/env bash
# guard-stack-rebase — PreToolUse gate on Bash, scoped to the
# rebase-pr-stack skill.
#
# The skill body states these rules; this is what makes them hold, since
# instructions degrade under a long context and an exit-2 deny does not.
#
# Four rules, in the order they fire:
#
#   1. Starting the cascade by hand is refused. `gh stack rebase` moves
#      every branch, and the tips it moves them from stop existing at
#      that moment. start-cascade.sh records them first, and without
#      that recording no range-diff can say what the replay did to any
#      commit. Resuming and abandoning stay open: --continue and
#      --abort both need the rebase that is already running, and the
#      moment someone reaches for --abort is the wrong moment to make
#      them read a refusal.
#   2. `gh stack sync` is refused. Sync rebases and force-pushes in one
#      operation, which puts every branch on the remote before anything
#      has read the replay. push-stack.sh calls it, after the
#      verification passes.
#   3. `gh stack submit` is refused for the same reason: it pushes.
#   4. A bare `git push --force` is refused. A cascade rewrites several
#      branches at once, so this is the move that follows it, and the
#      lease is what keeps it from discarding work pushed elsewhere.
#   5. A bare stash restore is refused. Worktrees share one global stash
#      stack whose indices shift whenever any worktree pushes an entry.
#
# Exit 2 blocks and hands stderr back as the reason. Exit 0 defers to
# the normal permission flow.
set -euo pipefail

# --- environment hardening -------------------------------------------
export LC_ALL=C
export PYTHONUTF8=1
unset CDPATH GH_REPO GH_HOST GREP_OPTIONS
IFS=$' \t\n'

payload=$(cat)
command=$(jq -r '.tool_input.command // ""' <<<"$payload")

deny() {
  printf 'Blocked by the rebase-pr-stack skill guard.\n\n%s\n' "$1" >&2
  exit 2
}

# Heredoc bodies are data, not commands. A script written through a
# heredoc can name these commands in its comments or its prose, and
# matching that text refuses a call that never touched a branch.
command=$(printf '%s' "$command" | awk '
  {
    if (term != "") {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (line == term) { term = "" }
      next
    }
    rest = $0
    while (match(rest, /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/)) {
      word = substr(rest, RSTART, RLENGTH)
      rest = substr(rest, RSTART + RLENGTH)
      gsub(/^<<-?[ \t]*|["'"'"']/, "", word)
      term = word
    }
    print
  }
')

# The subcommand has to sit where a command actually starts. The newline
# has to be a real one: POSIX ERE reads \n as the letter n.
readonly AT_START=$'(^|[;&|(]|&&|\\|\\||\n)[[:space:]]*'
readonly GIT_CMD='git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+'

# Rule 1: the cascade records before it moves.
if [[ $command =~ ${AT_START}gh[[:space:]]+stack[[:space:]]+rebase ]]; then
  if ! [[ $command =~ [[:space:]]--(continue|abort)([[:space:]]|$) ]]; then
    deny "\`gh stack rebase\` moves every branch in the stack, and the tips it moves
them from stop existing at that moment. Without them no range-diff can say
what the replay did to any commit, so a resolution that dropped a hunk goes
out with the push.

  bash .claude/skills/rebase-pr-stack/scripts/start-cascade.sh <number|branch>

It records every branch tip, then runs the same cascade.

Resuming and abandoning an existing cascade stay open:

  gh stack rebase --continue
  gh stack rebase --abort"
  fi
fi

# Rules 2 and 3: the commands that push.
if [[ $command =~ ${AT_START}gh[[:space:]]+stack[[:space:]]+sync ]]; then
  deny "\`gh stack sync\` rebases and force-pushes in one operation, so every
branch reaches the remote before anything has read what the replay did to
it. That is the gap this skill exists to hold open.

The cascade and the push are separate steps here:

  1. bash .claude/skills/rebase-pr-stack/scripts/start-cascade.sh <number>
  2. bash .claude/skills/rebase-pr-stack/scripts/verify-cascade.sh
  3. bash .claude/skills/rebase-pr-stack/scripts/push-stack.sh

Step 3 calls sync itself, once the verification is clean."
fi

if [[ $command =~ ${AT_START}gh[[:space:]]+stack[[:space:]]+submit ]]; then
  deny "\`gh stack submit\` pushes every branch and opens or updates the pull
requests behind them. Neither belongs in the middle of a cascade nobody has
verified yet.

Pushing a verified cascade:

  bash .claude/skills/rebase-pr-stack/scripts/push-stack.sh

Opening a pull request for a new member goes through the pr skill."
fi

# Rule 4: the lease.
if [[ $command =~ ${AT_START}${GIT_CMD}push ]]; then
  if [[ $command =~ [[:space:]](--force|-f)([[:space:]]|$) ]] &&
    ! [[ $command =~ --force-with-lease ]]; then
    deny "A bare --force overwrites the remote branch whatever it now holds. After a
cascade that is the whole risk, several branches over: each one has been
rewritten here, and anything pushed to any of them elsewhere is what --force
discards.

push-stack.sh pushes the stack through gh stack sync, whose force is
--force-with-lease and whose push is --atomic. For one branch by hand:

  git push --force-with-lease origin HEAD"
  fi
fi

# Rule 5: a stash restore names its own entry.
if [[ $command =~ ${AT_START}${GIT_CMD}stash[[:space:]]+(pop|apply) ]]; then
  if ! [[ $command =~ stash[[:space:]]+(pop|apply)([[:space:]]+-[^[:space:]]+)*[[:space:]]+(stash@|[0-9a-f]{7,}) ]]; then
    deny "Worktrees share one global stash stack, and its indices shift whenever any
worktree pushes an entry. A bare pop takes whatever sits at stash@{0} right
then, which may be another session's work.

Name the entry:

  git stash list --format='%gd %gs'
  git stash apply stash@{n}

Then drop that entry by the same name."
  fi
fi

exit 0
