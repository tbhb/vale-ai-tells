---
name: rebase-pr-stack
license: Apache-2.0
description: >-
  Replay a whole stack of pull requests onto its trunk and establish that the result is sound before any of it reaches the remote. The cascade runs through the gh stack extension, but the recording of every branch tip happens first, because a range-diff of what the replay did needs tips that stop existing the moment a branch moves. Verification sits between the cascade and the push, which is the gap gh stack sync has no room for. Conflicts route to resolve-rebase-conflicts. Use this whenever a stack is behind its trunk, whenever GitHub rebased members after a merge below them, and whenever a workflow needs a stack brought current.
hooks:
  PreToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: "${CLAUDE_PROJECT_DIR}/.claude/skills/rebase-pr-stack/scripts/guard-stack-rebase.sh"
---

# Rebase a stack of pull requests

Move every branch in the stack onto the one below it, then establish that what came out is right, and only then push.

The `gh stack` extension performs the cascade, and it does that part well: it replays each branch onto its updated parent in order, and it restores every branch when it cannot finish. What it does not do is tell anyone what the replay changed. `gh stack sync` goes further in the wrong direction for this purpose, rebasing and force-pushing in one operation, so every branch is on the remote before anything has read a line of the result.

So this skill splits that operation in half and puts the verification in the middle. `start-cascade.sh` records every branch tip and then runs the same cascade the extension would. `verify-cascade.sh` pairs each branch against its recorded self with a range-diff. `push-stack.sh` re-runs that verification and pushes through `gh stack sync` only when it comes back clean.

A guard hook refuses the shortcuts: a cascade started by hand, `gh stack sync`, `gh stack submit`, a force push without a lease, and a bare stash pop.

## Preflight

!`bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh ${ARGUMENTS}`

## Step 0: the checklist

Track these steps with the session's task-list tools where it carries them. Newer harnesses leave those tools out by default, and a session without them works the list in order as written.

1. Confirm the stack and whether anything needs moving
2. Make the extension aware of the stack
3. Settle the working tree
4. Cascade
5. Resolve whatever it stops on
6. Verify
7. Push
8. Report

Preflight reporting a merge or a cherry-pick in progress stops everything. A cascade already in progress resumes at step 5.

## Step 1: confirm the stack

Preflight printed the chain under `== the stack ==`, derived by following each pull request's base to whichever open pull request publishes that branch. A base nothing publishes is the trunk.

`== what this run has to do ==` is the answer that decides whether to go on. Every member already carrying its base means the cascade would replay nothing, so say that and stop. The operator can still have a reason to run one, the usual being local copies left behind after a member merged, and that reason belongs in the report.

Where preflight reported branching, two open pull requests share one base. That is a tree, and nothing here can tell which limb was meant. Name the top of the intended one as the argument.

## Step 2: make the extension aware of the stack

The cascade acts on a stack the extension tracks, and a stack assembled by setting a base on each pull request leaves nothing on this machine. Preflight printed the state under `== local stack tracking ==`, with the adoption command already filled in when it found none:

```text
gh stack init <bottom-branch> [<next> ...]
```

Every branch it names has to exist locally. The `== branches ==` block says which do, and a member marked `ABSENT` cannot be cascaded or verified here. Fetch it, or run against the part of the stack this machine has and say which part that was.

## Step 3: settle the working tree

The cascade checks out every branch in turn, so a dirty tree either blocks it or follows it from branch to branch. Park anything uncommitted in a throwaway commit first:

```text
git commit -am wip --no-verify
```

That is the one sanctioned `--no-verify` in this repository, and `git reset --soft HEAD~1` unwinds it once the cascade is done. Prefer it to a stash here: worktrees share one stash stack, and a cascade is long enough for another session to push an entry onto it.

## Step 4: cascade

```text
bash .claude/skills/rebase-pr-stack/scripts/start-cascade.sh <number|branch>
```

It records each branch tip under the git directory, then runs `gh stack rebase`. The recording is what step 6 measures against, and it is why the cascade does not start by hand. Pass `--no-trunk` where the trunk should stay out of it, which is the case when the members need to line up with each other but the trunk has moved for reasons this branch should not absorb yet.

## Step 5: resolve whatever it stops on

The extension stops on the first conflict and leaves a rebase in progress. Resolve it through the `resolve-rebase-conflicts` skill, stage each path, then resume:

```text
gh stack rebase --continue
```

Abandoning restores every branch to the recorded tips:

```text
gh stack rebase --abort
```

Both stay open to the guard. A cascade several branches deep can stop more than once, and each stop is its own resolution.

## Step 6: verify

```text
bash .claude/skills/rebase-pr-stack/scripts/verify-cascade.sh
```

Each member is paired against the member below it, before and after, so the range-diff compares the branch's own commits rather than everything the parent contributed. Read each pairing before its diff. A `=` replayed unchanged. A `!` moved, which is what a resolved conflict looks like and is suspicious anywhere else. A `<` or `>` means a commit vanished or appeared, and that is the finding this whole arrangement exists to surface.

It also reports committed conflict markers, a dirty tree, and the gate to run. Run that gate on the top of the stack at least, where every member's changes are present at once. Each commit passed the hooks in isolation; this combination has never been tested.

Nothing is pushed while it flags anything, and `push-stack.sh` enforces that by running it again rather than trusting that someone read it.

## Step 7: push

A cascade rewrites every branch above the first one that moved, so this rewrites several remote branches at once. Confirm with the operator before running it, naming the branches the verification listed under `== what changes on the remote ==` and which of them are rewrites rather than fast-forwards. Where `mise run preapprove` granted a standing answer, it does not cover this: that grant names merging.

```text
bash .claude/skills/rebase-pr-stack/scripts/push-stack.sh
```

It re-runs the verification, prints what each branch does on the remote, then pushes through `gh stack sync`. The force there is `--force-with-lease` and the push is `--atomic`, so a branch that moved underneath this machine refuses the push and the remote takes all the branches or none. Sync relinks the pull requests into a stack on GitHub afterwards.

A refused lease means someone pushed to one of these branches after the cascade started. Nothing partial landed. Fetch, read what arrived, and cascade again from there.

## Step 8: report

Name each branch that moved, what the range-diff said about it, and anything a resolution changed. Say which gate ran and against which member. Where the run stopped before the push, say what is still local.

## Preconditions

- `gh` installed and authenticated, with the `github/gh-stack` extension
- the `resolve-rebase-conflicts` skill deployed alongside this one
- the `rebase` skill deployed, whose `marker-scan.sh` decides which conflict-marker candidates are real

Preflight checks the first two. Without `marker-scan.sh` the verification names marker candidates rather than judging them, which is a weaker report rather than a broken one.
