#!/usr/bin/env bash
# guard-stack-merge — PreToolUse gate on Bash, scoped to the
# merge-pr-stack skill.
#
# The merge-pr guard governs `gh pr` and nothing else. `gh stack merge`
# is a different top-level command, so it passes that guard untouched,
# and what it does is the one thing this toolchain exists to prevent:
# it merges every member of the stack in one atomic operation, and it
# takes no --subject and no --body. Every message GitHub writes there
# is the concatenation of the branch's commits, which no commit-msg
# hook has ever read, landing on the default branch where the rest of
# the toolchain assumes those hooks ran. One call does that once per
# member.
#
# So the rule here is narrow and absolute: the atomic stack merge is
# refused, and merging runs bottom-up through the merge-pr skill, whose
# own script supplies a reviewed and linted message per member.
#
# `gh stack` is otherwise left alone. Reading a stack is how this
# workflow orders itself, and rebasing one belongs to rebase-pr-stack.
#
# The direct `gh pr merge` is refused too. This guard outlives the turn
# that installed it, and a session that has been merging a stack is
# exactly the one that reaches for a single-pull-request shortcut.
#
# Exit 2 blocks and hands stderr back as the reason. Exit 0 defers to
# the normal permission flow.
set -euo pipefail

# --- environment hardening -------------------------------------------
# The agent reads this output, so the operator's preferences must not
# change its shape. LC_ALL pins the [a-z] ranges the patterns below use.
export LC_ALL=C
export PYTHONUTF8=1
unset CDPATH GH_REPO GH_HOST GREP_OPTIONS
IFS=$' \t\n'

payload=$(cat)
command=$(jq -r '.tool_input.command // ""' <<<"$payload")

deny() {
  printf 'Blocked by the merge-pr-stack skill guard.\n\n%s\n' "$1" >&2
  exit 2
}

# Heredoc bodies are data, not commands. A script written through a
# heredoc can name these commands in its own comments or prose, and
# matching that text refuses a call that never touched a pull request.
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

# The subcommand has to sit where a command actually starts, so a
# mention of it inside an argument reads as the prose it is. The
# newline has to be a real one: POSIX ERE reads \n as the letter n.
readonly AT_START=$'(^|[;&|(]|&&|\\|\\||\n)[[:space:]]*'

if [[ $command =~ ${AT_START}gh[[:space:]]+stack[[:space:]]+merge ]]; then
  deny "\`gh stack merge\` merges the whole stack in one atomic operation and
takes no --subject and no --body. Every squash message it leaves behind
is GitHub's concatenation of the branch's commits, which nothing has
linted and no reviewer has read, once per member.

A stack merges bottom-up instead, one member at a time:

  1. Invoke the merge-pr skill with the bottom member's number. It
      drafts the message, has review-squash-message clear it, runs the
      commit-msg gates, confirms with the operator, and merges.
  2. bash .claude/skills/merge-pr-stack/scripts/advance-stack.sh
  3. Repeat for the member that is now the bottom.

Reading a stack stays open: gh stack view runs without asking."
fi

if [[ $command =~ ${AT_START}gh[[:space:]]+pr[[:space:]]+merge ]]; then
  deny "\`gh pr merge\` writes a squash message nothing reviewed or linted, and
nothing lints a squash commit after the fact.

Merging one member runs through the merge-pr skill, which supplies the
message and puts it through what a commit answers to. This skill
orchestrates that bottom-up; it does not replace it."
fi

exit 0
