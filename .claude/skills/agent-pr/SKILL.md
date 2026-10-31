---
name: agent-pr
description: >-
  Open or update a pull request unattended through the shared PR gates and independent review. Use for delegated agent branches that must report a hold instead of asking for confirmation. Requires a machine GitHub identity and session pre-approval or machine delegation.
hooks:
  PreToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: "${CLAUDE_PROJECT_DIR}/.claude/skills/pr/scripts/guard-gh.sh"
---

# Publish unattended

Use `gh-post` for issue and PR content, comments, reviews, comment edits, and release notes. Supply body text through `--body-file` or stdin. If `gh-post` is missing, stop and report the missing command. Never fall back to a direct GitHub content write.

Never prompt, use `AskUserQuestion`, pass `--confirmed`, or create a pre-approval record.

Missing authority returns 75. Report the hold and preserve the draft. Install the sibling `pr` and `review-pr-description` skills from the same package.

1. Commit the branch through `agent-commit`, then run `bash .claude/skills/agent-pr/scripts/preflight.sh`. Stop for a dirty tree, an interrupted Git operation, detached `HEAD`, a missing machine `gh_login`, or no commits to publish.
2. Fill `PR_AGENTDESC.md` using the scaffold, repository template, labels, and base from preflight. The draft supplies the title, properties, sections, and draft state. Use `draft: false` to mark an existing PR ready. Keep issue references in the repository's configured Related grammar. Omit the configured owner-review label. Only the owner-approval route applies it after approval at the current head, green checks, and a mergeable state. Updates preserve the label when it already exists on GitHub.
3. Run `bash .claude/skills/agent-pr/scripts/check.sh`. This runs shared validation, repository lint, and the configured log, Related, and title checks. Fix every finding before review.
4. Run `bash .claude/skills/agent-pr/scripts/review.sh`. The script reviews committed snapshots and stamps the exact draft, branch, head, base, merge base, and repository configuration. Findings return 2. The configured finding bound returns 3 and requires the redesign procedure below. Failed reviewer execution returns 4, and changed inputs return 5. Neither spends a finding round.
5. Run `bash .claude/skills/agent-pr/scripts/publish.sh`. It runs the shared leak, lint, test, review, stamp, identity, and confirmation gates. Session pre-approval or machine delegation must grant `pr`. The account must match machine `gh_login`. The script checks again after delegation and push. Every PR property converges on the reviewed draft.
6. Report the URL, full head, and draft state from the result. Stop after publication. Merge belongs to `agent-merge-pr` when that skill is available.

Publication normally requires a forward push. Use `--rewrite` only on the operator's explicit authorization for that branch. It leases on the exact known remote commit and refuses when `HEAD` is behind origin or the remote commit wasn't fetched. A failed or uncertain GitHub write requires inspection before retrying.

## Reviewer and publish access

`review_cmd` chooses the reviewer. From Codex, configure one the session may start. These repository machines put this line in `~/.config/devtools/devtools.conf` so `agy` reviews in read-only plan mode:

```text
review_cmd = agy -p "$(cat)" --mode plan --add-dir "$DEVTOOLS_REVIEW_INPUTS" --print-timeout 900s
```

After the operator authorizes that rewrite, they can add `Bash(bash .claude/skills/agent-pr/scripts/publish.sh --rewrite)` to `permissions.allow` in their Claude Code settings. This is the exact unattended publish form. An owner adds the permission, never the agent.

## Repository configuration

Repository settings are declarative lines in `.agents/agent-skills.conf`: `pr_template`, `lint_pr_cmd`, `pr_log_entry`, `pr_related_pattern`, `pr_title_check_cmd`, `owner_paths`, `review_max_rounds`, and optional `mail_cmd`, `mail_to`, and `mail_from`. Commands execute at their configured gate, never by sourcing the file. Authorities remain in machine configuration. Owner paths add `--owner-path` to the delegation check when any changed path on the branch matches.

A successful publication records `pr.result.json` under the worktree's Git `agent-skills` directory and resets the finding counter. Reports print locally unless configuration specifies a mailbox command and recipient. A failed report delivery prints the report without retrying publication. See the consumer migration note in devtools for settings and cleanup.

When the unattended finding bound returns exit 3, run `agentrepo review redesign KIND --reason TEXT` with `KIND` set to `commit`, `pr` or `squash`, then rewrite the draft from scratch. A rejected digest for the same subject refuses review before invoking the reviewer. Each active record permits one redesign. A bound after redesign requires inspection and refuses another start. Legacy records without rejected digests require inspection. The command leaves write authority and every other gate unchanged. A fresh description reset, where supported, remains separate from redesign.
