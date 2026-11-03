# Dispatching agents from Claude Code

Every step that hands work to other agents uses the `Agent` tool. Fill in the placeholders in the prompt each reference file gives, and pass that text as `prompt`.

## Locating a session

One agent, the cheapest model, because the answer is a path:

```text
Agent({
  subagent_type: "Explore",
  model: "haiku",
  description: "Locate a session transcript",
  prompt: `<THE LOCATE MESSAGE>`,
})
```

## Verifying figures

Send three agents in one message, each with the same prompt:

```text
Agent({
  subagent_type: "Explore",
  model: "sonnet",
  description: "Verify retrospective figures",
  prompt: `<THE VERIFIER PROMPT>`,
})
```

A verifier that writes to the filesystem needs its own checkout, so spawn it with `isolation: "worktree"`.

## Recommending fixes

Send five agents in one message, one per area:

```text
Agent({
  subagent_type: "Explore",
  description: "<AREA> recommendations",
  prompt: `<THE SHARED PROMPT, WITH ITS AREA BLOCK>`,
})
```
