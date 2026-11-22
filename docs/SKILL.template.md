---
name: {{skill}}
description: EverMe personal memory — recall earlier conversations, decisions, conventions, and solved problems, and save durable preferences and decisions. Tools live on the `{{server}}` MCP server and are reached from mbtx scripts.
---

# EverMe memory

This workspace has the user's EverMe personal memory: one pool shared across
their devices and agents. Its tools are **not** native tools — they are on the
`{{server}}` MCP server and are called from a MoonBit script.

## If this machine has no account yet

The server is a MoonBit package: the config launches it through `moonx`, which
ships with the toolchain and resolves the pinned version on first use. On a
machine that has never logged in:

```bash
moonx {{coordinate}} auth login     # or: moonx {{coordinate}} auth adopt-evercli
```

That stores the account key and binds this machine as an agent. If the tools
still answer "no agent", `moonx {{coordinate}} auth register` binds it again and
`moonx {{coordinate}} doctor` says what is missing.

Until then the tools below are not reachable.

## When to recall

Call `mem_search` when the user points at something earlier: "last time",
"remember when", "what did we decide about X", "didn't we fix this before",
or when the task depends on conventions and decisions made before this chat.

```mbtx
---
import {
  "moonbitlang/openseek_tools@0.4.1/mcp",
  "moonbitlang/core/async",
}
---

async fn main {
  let reply = @mcp.call("{{server}}", "mem_search", { "query": "short keywords" })
  println(reply.content)
}
```

Rules that keep recall useful:

- Keep `query` to a few keywords; never paste the conversation.
- Do not repeat an identical query within one turn.
- Rows under *Recent unextracted transcript — provisional* are not extracted
  memories. Never quote them as established facts.
- If the answer is already in this conversation or in the workspace, prefer it.

## When to save

The user states something durable about themselves — a preference, habit,
trait, long-term goal, or decision — save it immediately, without being asked:

```mbtx
async fn main {
  let reply = @mcp.call("{{server}}", "mem_save_fact", { "fact": "…" })
  println(reply.content)
}
```

Only `extracted: true` / `profileUpdated: true` in the reply means the profile
really updated. On `no_extraction`, say the fact was recorded but not yet
extracted — do not claim it was remembered, and do not retry in a loop.

When a task was solved in a way worth reusing, save the trajectory with
`mem_save_turn` (user → tool calls → results → answer). Use `mem_save_fact`
for a stated preference instead of relying on the derived transcript.

Save at milestones, not only at the end. A long task can be interrupted at the
context ceiling, and whatever was never saved is then only in the compressed
summary. Saving the trajectory so far keeps the finished part out of its hands.
Write the milestone note so it can stand alone: what is done, what is next,
and the constraints that must not be broken. A summary often keeps the first
and loses the other two, which is where resuming actually costs time.

## After a context checkpoint

A turn that ends with `[context ceiling] … was checkpointed` did not hand you the
transcript: you are continuing from a summary the previous turn wrote about
itself. Summaries keep what looked important and drop parameters, boundaries and
constraints — the things that are usually the point.

- **A summary's silence is not evidence.** Before concluding that a decision was
  never made, a step was never done, or the user never asked for something,
  check instead of assuming.
- Search first: `mem_search` with the current task's keywords, then
  `mem_context` for the user's durable constraints.
- The workspace's real state — `git status`, `git diff`, the files themselves —
  outranks any recollection, yours or the summary's.
- Resume by stating where the work actually stands and what is next, then do only
  the missing part. Never redo a finished step because the summary forgot it.
- A continuation turn is not a question. Nothing has been asked of the user and
  nothing is waiting for them: report in one line where things stand, then take
  the next step. Do not ask whether to continue, and do not stop to confirm.
- Keep the working set small. Store a digest of long output and cite it instead
  of pasting it back; every token kept out of the context is one the next
  checkpoint does not have to compress away.

## Profile at the start of a session

If no profile block was injected into this conversation and the task depends on
who the user is, call `mem_context` once. It returns the durable Profile only —
no search, no episodes. Do not fetch it again later in the same session.