---
name: agent-merge-pr
description: >-
  Squash merge unattended through the shared merge gates and independent review. Use for delegated agent merges that must report a hold instead of asking for confirmation. Requires machine identities, exact-head approval, and session pre-approval or machine delegation.
hooks:
  PreToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: "${CLAUDE_PROJECT_DIR}/.claude/skills/merge-pr/scripts/guard-merge.sh"
---

# Merge unattended

Use `gh-post` for issue and PR content, comments, reviews, comment edits, and release notes. Supply body text through `--body-file` or stdin.

If `gh-post` is missing, stop and report the missing command. Never fall back to a direct GitHub content write.

Never prompt, use `AskUserQuestion`, pass `--confirmed`, or create a pre-approval record. Missing authority holds the merge.

Install sibling `merge-pr` and `review-squash-message` from the same package. The policy reader requires `uv` and `agentrepo checks evaluate`.

1. Run `bash .claude/skills/agent-merge-pr/scripts/preflight.sh <pr>`. Stop for a dirty tree, interrupted Git operation, detached head, missing machine identity or required reviewer, missing required checks, or unreadable policy. No checks means no merge.
2. Read the published description and all commits. Run `bash .claude/skills/agent-merge-pr/scripts/squash-message.sh <pr>` for the full briefing and skeleton. Write the squash body in `SQUASH_AGENTMSG`, explaining why the branch exists. Keep the PR reference and complete trailers. Add closing references only for work this delivery completes.
3. Run `bash .claude/skills/agent-merge-pr/scripts/lint-squash-msg.sh <pr>`, then `bash .claude/skills/agent-merge-pr/scripts/review.sh <pr>`. The lint wrapper reads cspell policy from the pinned pull request head. Under the policy and approval checks, the shared review script gathers pinned Git objects and independently reviews the message. Review stamps bind the message, head, base, and repository configuration. Findings return 2. The persistent bound returns 3. Failed execution, timeout, and input drift don't spend a finding round.
4. Run `bash .claude/skills/agent-merge-pr/scripts/merge.sh <pr>`. The shared merger requires the stamped inputs, a current exact-head approval from machine `required_reviewer`, successful required checks, readiness, and session pre-approval or machine delegation for `merge`. It checks live policy and authority again after delegation and changing the base branches of dependent pull requests. It never uses administrator or automatic merge.
5. Report the full merge commit, owner paths, any owner override and its login, and retained branches or worktrees. A failed or uncertain write requires inspection before retrying. A remote message mismatch preserves evidence and skips cleanup.

Repository behavior comes from declarative `.agents/agent-skills.conf`.

Authorities come only from machine configuration: `gh_login`, `required_reviewer`, optional `required_reviewer_type`, optional `merge_owner`, reviewer selection, and delegation. Golden files and detected gate loosening require an APPROVED review from `merge_owner` on the exact current head. A later push invalidates it. The owner-review label still holds the merge.

The protected-path scan reads APM ownership from the pinned base lockfile and skips non-local deployments. It ignores full comment lines and matches exclusion keys rather than words inside values. Repository policy changes require the same owner approval. Reviewers must still identify policy changes the scan can't detect.

The merger verifies the landed message before cleanup and leases remote branch deletion on the reviewed head. It retains fork branches and preserves current, dirty, non-agent, or valuable ignored-file worktrees. See the consumer migration note for settings and removal of local skill copies.

Configure `required_reviewer` and `merge_owner` with GraphQL logins, without the REST `[bot]` suffix. Optional machine `required_reviewer_type` accepts `Bot` or `User`. Unset keeps login-only matching. It checks only the required reviewer.

Keep `merge_owner` a person: an App owner override can approve its own golden-file waivers.

A GitHub App installation needs Contents read and write permission for its approval to count, as [#300](https://github.com/tbhb-dev/devtools/issues/300) documents.

When the unattended finding bound returns exit 3, run `agentrepo review redesign KIND --reason TEXT` with `KIND` set to `commit`, `pr` or `squash`, then rewrite the draft from scratch. A rejected digest for the same subject refuses review before invoking the reviewer. Each active record permits one redesign. A bound after redesign requires inspection and refuses another start. Legacy records without rejected digests require inspection. The command leaves write authority and every other gate unchanged. A fresh description reset, where supported, remains separate from redesign.
