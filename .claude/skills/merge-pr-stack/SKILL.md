---
name: merge-pr-stack
license: Apache-2.0
description: >-
  Land a stack of pull requests bottom-up, one member at a time, each under a squash message this toolchain wrote. GitHub's own atomic stack merge takes no subject and no body, so it leaves one unlinted message per member on the default branch; this skill refuses it and orchestrates the merge-pr skill instead. A preflight derives the chain from the base pointers rather than from local tracking, so it works from a root session. Between members it waits for GitHub to retarget the rest. Use this whenever the user asks to merge or land a stack, or more than one pull request that builds on another.
hooks:
  PreToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: "${CLAUDE_PROJECT_DIR}/.claude/skills/merge-pr-stack/scripts/guard-stack-merge.sh"
---

# Merge a stack of pull requests

This skill orders the run and nothing else. Every member still merges through the `merge-pr` skill, which drafts the squash message, has `review-squash-message` clear it, runs the commit-msg gates, and confirms with the operator. What this adds is the order, the wait between members, and a refusal.

The refusal is the point. `gh stack merge` lands the whole stack in one atomic operation, and it accepts no `--subject` and no `--body`. Every message it leaves behind is GitHub's concatenation of a branch's commits, which no commit-msg hook has read, arriving on the default branch where the rest of the toolchain assumes those hooks ran. One call does that once per member, and nothing lints a squash commit afterwards. A guard hook refuses it, and refuses a direct `gh pr merge` alongside.

Merging a middle member is the same failure wearing a different hat. GitHub merges everything below it too, so a run that names the top lands the whole stack while this workflow supplied a message for one of them.

## Preflight

!`bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh ${ARGUMENTS}`

## Step 0: the checklist

Track these steps with the session's task-list tools where it carries them. Newer harnesses leave those tools out by default, and a session without them works the list in order as written.

1. Confirm the chain and its order
2. Merge the bottom member through `merge-pr`
3. Wait for the cascade
4. Repeat from step 2 until the stack is gone
5. Report what landed

## Step 1: confirm the chain

Preflight printed it under `== the stack ==`, derived by following each pull request's base to whichever open pull request publishes that branch. A base nothing publishes is the trunk, and the walk stops there. Local stack tracking never enters into it, because a stack assembled by setting a base on each pull request leaves nothing on this machine, and because merges run from a root session on the default branch where `gh stack view` reports no stack at all.

Read the order against what the operator asked for. Where preflight reported branching, two open pull requests share one base, which is a tree rather than a stack. Nothing here can tell which limb was meant, so name the top of the intended one as the argument and run preflight again.

Stop before anything merges where a member is a draft, where the review decision is `CHANGES_REQUESTED`, or where preflight found no `merge-pr` skill deployed.

A member with failing checks does not stop the run on its own. Only the bottom one merges next, so a red member three layers up has time to go green. Read the readiness block for the bottom member alone, and hand a failure there to `fix-pr` and a running check to `watch-pr`.

## Step 2: merge the bottom member

Invoke the `merge-pr` skill, passing the bottom member's number. Everything that decides what the commit says lives there: the briefing, the drafted message, the independent review, the gates, and the confirmation.

Two things about that workflow matter here.

Its preflight removes a `SQUASH_AGENTMSG` drafted for a different pull request, so the draft left by the previous member cleans itself up rather than following the loop into the next one.

Its confirmation is per member. Where the operator granted `mise run preapprove merge`, that grant answers the question once for each member rather than once for the run, and each message still gets printed before its merge. Ask anyway wherever `merge-pr` says to ask: a review finding nobody acted on, checks that are not green, or a member the session did not set out to merge.

Nothing about a stack changes the message. A squash message stands for the branch it collapses, and the branch below it already has its own commit on the default branch by then.

## Step 3: wait for the cascade

Arm the wait through the `Monitor` tool, which turns each line the script prints into a notification:

```text
Monitor({
  command: "bash .claude/skills/merge-pr-stack/scripts/advance-stack.sh <merged-number>",
  description: "stack cascade after #<merged-number>",
  timeout_ms: 600000,
  persistent: false,
})
```

GitHub retargets and rebases the members above the one that merged, and it does that asynchronously. A session that reads the next member straight after the merge sees it still pointing at a branch that no longer exists and concludes the stack is broken. The script waits for the retarget instead of sampling once, and it reports each member the moment that member lands rather than holding everything until the close. A wait that prints nothing until it ends cannot be told from a wait that has hung.

The lines to expect:

- `MERGED #<number>` once, confirming the member this run follows
- `WAITING <n> member(s) still to retarget`, only when any still have to move
- `RETARGETED #<number> (was on <branch>)`, one per member as GitHub moves it
- `DIVERGED <branch> (<n> ahead, <m> behind origin)`, one per local copy the cascade left behind
- `SETTLED`, `TIMEOUT`, or `ERROR` to close, with `NEXT` after a clean settle

Running the same command through `Bash` also works and blocks until the same ending, with the exit code reporting the outcome: `0` the stack is ready for the next merge, `1` something needs an answer first. Prefer `Bash` here, because the next member cannot merge until this answer arrives and nothing else in the loop can start meanwhile. Reach for `Monitor` on a deep stack, where the per-member lines are worth having as they land.

Never poll `gh pr list` in a loop of your own. Each look costs a turn and reports a state that has already moved on.

Override the bounds through the environment where a cascade is unusually slow. `STACK_RETARGET_TIMEOUT` sets the whole wait and `STACK_RETARGET_POLL` the spacing, both in seconds. Keep `timeout_ms` past `STACK_RETARGET_TIMEOUT` so the script reports its own timeout rather than dying at the tool's.

The `DIVERGED` lines do not block the next merge. `merge-pr` reads the pull request rather than the worktree. They matter to anyone about to work on one of those branches, and bringing them across belongs to `rebase-pr-stack`.

A `TIMEOUT` stops the loop. A member still pointing at a deleted branch after that long is not a slow cascade, and retargeting a pull request by hand is a decision for the operator rather than a step in a loop.

## Step 4: repeat

Run the preflight again, naming the top of what is left, and go back to step 2. The member that was second is the bottom now.

Each pass merges one member. A stack four deep is four passes, four messages, four reviews, and four confirmations, which is the cost of every message on the default branch having been read by something.

## Step 5: report

Name each member that landed, with its merged commit, in the order they went in. Say what is still open where the run stopped early, and why it stopped.

`merge-pr` deletes each merged branch as it goes, so the cleanup needs nothing here. Where this worktree stands on a branch that merged, that script says so rather than deleting it underneath the session.

## Preconditions

- `gh` installed and authenticated
- the `merge-pr` and `review-squash-message` skills deployed alongside this one
- a `mise run lint-squash-msg` task, and a gitignore entry for `SQUASH_AGENTMSG`

Preflight checks each. Where one is missing, tell the operator rather than improvising a substitute.
