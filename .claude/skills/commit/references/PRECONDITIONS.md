# Commit skill preconditions

The commit skill assumes the shared tbhb toolchain:

- a `mise run lint-commit-msg` task
- a gitignore entry for `COMMIT_AGENTMSG`
- the prek hooks installed, including the post-commit stage
- the `review-commit-message` and `fix-prose` skills deployed alongside this one
- the harness's CLI on `PATH`, for the headless reviewer

Preflight checks most of these. When one is missing, tell the operator rather than improvising a substitute.

Only the repository holding the session can commit through this workflow. Its root is where the review snapshots the draft and the diff, and the commit script reads the draft and the stamp from whichever repository it runs in. A sibling checkout has no stamp of its own. Rather than commit on a review that read another tree, the script stops. To commit a different repository, open a session there.
