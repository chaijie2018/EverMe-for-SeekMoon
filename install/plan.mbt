// What `everme-seekmoon install` writes, as pure functions: the skill document, the
// `mcpServers` entry, the merge into an existing config, and the marked block for
// a workspace's AGENTS.md.
//
// Keeping the text and the merges here means the interesting behaviour — never
// dropping a user's other servers, never duplicating our block, never inventing a
// value — is testable without touching the filesystem.

///|
/// The MCP server name. Stable on purpose: a skill, this CLI, and any docs must
/// agree on it, and a rename would silently disconnect every installed host.
pub const ServerName : String = "everme-seekmoon"

///|
/// The skill directory (and the skill's own name).
pub const SkillDirName : String = "everme-seekmoon"

///|
/// The file a host reads inside the skill directory.
pub const SkillFileName : String = "SKILL.md"

///|
/// The skill's own MCP config, which SeekMoon loads because it sits beside
/// `SKILL.md`.
pub const SkillConfigFileName : String = "mcp.json"

///|
/// The start of the managed block in `AGENTS.md`.
const AgentsBegin : String = "<!-- everme-seekmoon:begin — managed by `everme-seekmoon install`; edit outside these markers -->"

///|
/// The end of the managed block in `AGENTS.md`.
const AgentsEnd : String = "<!-- everme-seekmoon:end -->"

///|
/// The path of the binary to launch from `mcp.json`: an explicit `--command`, the
/// absolute `argv[0]`, an `argv[0]` relative to `cwd`, or a failure explaining
/// that `--command` is required. A path that `mcp.json` names must survive a
/// different working directory, so a bare program name is refused rather than
/// guessed from `PATH`.
pub fn resolve_command(
  explicit : String,
  argv0 : String,
  cwd : String,
) -> String raise {
  if !explicit.is_empty() {
    return explicit
  }
  if argv0.is_empty() {
    raise @api.ApiError({
      kind: "invalid_args",
      message: "cannot determine this binary's path: pass --command <path>",
      hint: "SeekMoon launches the server later, from another working directory",
      http_status: 0,
      code: 0,
      request_id: "",
    })
  }
  if argv0.has_prefix("/") {
    return argv0
  }
  if argv0.contains("/") {
    return cwd + "/" + argv0
  }
  raise @api.ApiError({
    kind: "invalid_args",
    message: "cannot determine this binary's path from \{argv0}: pass --command <path>",
    hint: "the server must be named by a path, not by a bare program name",
    http_status: 0,
    code: 0,
    request_id: "",
  })
}

///|
/// The `mcpServers` entry: how a host starts this server.
pub fn server_entry(command : String) -> Json {
  {
    "command": Json(command),
    "args": Json::array([Json("mcp"), Json("serve")]),
  }
}

///|
/// The skill's own `mcp.json`: one server, no secrets (the server reads its
/// credential store itself, so this file can be read and shared).
pub fn skill_config(command : String) -> String {
  let servers : Map[String, Json] = Map([(ServerName, server_entry(command))])
  let document : Json = { "mcpServers": Json::object(servers) }
  document.stringify()
}

///|
/// The skill document. The description is what a host lists, so it names the
/// triggers; the body is what the model reads when it opens the skill.
pub fn skill_markdown() -> String {
  let text =
    $|---
    $|name: \{SkillDirName}
    $|description: EverMe personal memory — recall earlier conversations, decisions, conventions, and solved problems, and save durable preferences and decisions. Tools live on the `\{ServerName}` MCP server and are reached from mbtx scripts.
    $|---
    $|
    $|# EverMe memory
    $|
    $|This workspace has the user's EverMe personal memory: one pool shared across
    $|their devices and agents. Its tools are **not** native tools — they are on the
    $|`\{ServerName}` MCP server and are called from a MoonBit script.
    $|
    $|## When to recall
    $|
    $|Call `mem_search` when the user points at something earlier: "last time",
    $|"remember when", "what did we decide about X", "didn't we fix this before",
    $|or when the task depends on conventions and decisions made before this chat.
    $|
    $|```mbtx
    $|---
    $|import {
    $|  "moonbitlang/openseek_tools@0.4.1/mcp",
    $|  "moonbitlang/core/async",
    $|}
    $|---
    $|
    $|async fn main {
    $|  let reply = @mcp.call("\{ServerName}", "mem_search", { "query": "short keywords" })
    $|  println(reply.content)
    $|}
    $|```
    $|
    $|Rules that keep recall useful:
    $|
    $|- Keep `query` to a few keywords; never paste the conversation.
    $|- Do not repeat an identical query within one turn.
    $|- Rows under *Recent unextracted transcript — provisional* are not extracted
    $|  memories. Never quote them as established facts.
    $|- If the answer is already in this conversation or in the workspace, prefer it.
    $|
    $|## When to save
    $|
    $|The user states something durable about themselves — a preference, habit,
    $|trait, long-term goal, or decision — save it immediately, without being asked:
    $|
    $|```mbtx
    $|async fn main {
    $|  let reply = @mcp.call("\{ServerName}", "mem_save_fact", { "fact": "…" })
    $|  println(reply.content)
    $|}
    $|```
    $|
    $|Only `extracted: true` / `profileUpdated: true` in the reply means the profile
    $|really updated. On `no_extraction`, say the fact was recorded but not yet
    $|extracted — do not claim it was remembered, and do not retry in a loop.
    $|
    $|When a task was solved in a way worth reusing, save the trajectory with
    $|`mem_save_turn` (user → tool calls → results → answer). Use `mem_save_fact`
    $|for a stated preference instead of relying on the derived transcript.
    $|
    $|Save at milestones, not only at the end. A long task can be interrupted at the
    $|context ceiling, and whatever was never saved is then only in the compressed
    $|summary. Saving the trajectory so far keeps the finished part out of its hands.
    $|Write the milestone note so it can stand alone: what is done, what is next,
    $|and the constraints that must not be broken. A summary often keeps the first
    $|and loses the other two, which is where resuming actually costs time.
    $|
    $|## After a context checkpoint
    $|
    $|A turn that ends with `[context ceiling] … was checkpointed` did not hand you the
    $|transcript: you are continuing from a summary the previous turn wrote about
    $|itself. Summaries keep what looked important and drop parameters, boundaries and
    $|constraints — the things that are usually the point.
    $|
    $|- **A summary's silence is not evidence.** Before concluding that a decision was
    $|  never made, a step was never done, or the user never asked for something,
    $|  check instead of assuming.
    $|- Search first: `mem_search` with the current task's keywords, then
    $|  `mem_context` for the user's durable constraints.
    $|- The workspace's real state — `git status`, `git diff`, the files themselves —
    $|  outranks any recollection, yours or the summary's.
    $|- Resume by stating where the work actually stands and what is next, then do only
    $|  the missing part. Never redo a finished step because the summary forgot it.
    $|- A continuation turn is not a question. Nothing has been asked of the user and
    $|  nothing is waiting for them: report in one line where things stand, then take
    $|  the next step. Do not ask whether to continue, and do not stop to confirm.
    $|- Keep the working set small. Store a digest of long output and cite it instead
    $|  of pasting it back; every token kept out of the context is one the next
    $|  checkpoint does not have to compress away.
    $|
    $|## Profile at the start of a session
    $|
    $|If no profile block was injected into this conversation and the task depends on
    $|who the user is, call `mem_context` once. It returns the durable Profile only —
    $|no search, no episodes. Do not fetch it again later in the same session.
  text
}

///|
/// The block `--agents-md` adds to a workspace's `AGENTS.md`.
pub fn agents_block() -> String {
  let text =
    $|\{AgentsBegin}
    $|This workspace has EverMe personal memory (MCP server `\{ServerName}`). Its tools
    $|are reached from mbtx scripts, not called directly:
    $|
    $|- The user refers to earlier conversations, decisions, or solved problems —
    $|  recall first: `@mcp.call("\{ServerName}", "mem_search", { "query": "short keywords" })`
    $|- The user states a durable preference or decision — save it:
    $|  `@mcp.call("\{ServerName}", "mem_save_fact", { "fact": "…" })`
    $|
    $|Rows under "Recent unextracted transcript — provisional" are not facts.
    $|Full instructions: the `\{SkillDirName}` skill.
    $|\{AgentsEnd}
  text
}

///|
/// Indent `json` by `depth` levels of two spaces, one field/branch per line.
/// Hand-written config is read by people, so the merge output stays readable
/// instead of collapsing to one line.
fn pretty(json : Json, depth : Int32) -> String {
  let indent = String::make(depth * 2, ' ')
  let inner_indent = String::make((depth + 1) * 2, ' ')
  match json {
    Object(fields) =>
      if fields.is_empty() {
        "{}"
      } else {
        let lines : Array[String] = []
        for name, value in fields {
          lines.push(
            "\{inner_indent}\{Json(name).stringify()}: \{pretty(value, depth + 1)}",
          )
        }
        "{\n\{lines.join(",\n")}\n\{indent}}"
      }
    Array(values) =>
      if values.is_empty() {
        "[]"
      } else {
        let lines : Array[String] = []
        for value in values {
          lines.push("\{inner_indent}\{pretty(value, depth + 1)}")
        }
        "[\n\{lines.join(",\n")}\n\{indent}]"
      }
    _ => json.stringify()
  }
}

///|
/// A whole config document, readable.
pub fn render_document(document : Json) -> String {
  pretty(document, 0) + "\n"
}

///|
/// The `mcpServers` map of a document, or a failure when the document is not the
/// shape this file is supposed to have. Refusing is the point: overwriting a
/// config we cannot read would destroy somebody else's servers.
fn servers_of(document : Json) -> Map[String, Json] raise {
  guard document is Object(root) else {
    raise @api.ApiError({
      kind: "invalid_args",
      message: "the existing MCP config is not a JSON object",
      hint: "fix or move it, then rerun install",
      http_status: 0,
      code: 0,
      request_id: "",
    })
  }
  match root.get("mcpServers") {
    None => Map([])
    Some(Object(servers)) => servers
    Some(_) =>
      raise @api.ApiError({
        kind: "invalid_args",
        message: "the existing MCP config has a non-object `mcpServers`",
        hint: "fix or move it, then rerun install",
        http_status: 0,
        code: 0,
        request_id: "",
      })
  }
}

///|
/// Parse an existing config document, or `{}` when there is none.
fn parse_document(existing : String?) -> Json raise {
  match existing {
    None => Json::empty_object()
    Some(text) =>
      if text.trim().is_empty() {
        Json::empty_object()
      } else {
        @json.parse(text) catch {
          _ =>
            raise @api.ApiError({
              kind: "invalid_args",
              message: "the existing MCP config is not valid JSON",
              hint: "fix or move it, then rerun install",
              http_status: 0,
              code: 0,
              request_id: "",
            })
        }
      }
  }
}

///|
/// Insert our entry into an existing document, leaving every other key and server
/// untouched. Returns the document to write.
pub fn merge_server(existing : String?, command : String) -> String raise {
  let document = parse_document(existing)
  let servers = servers_of(document)
  servers[ServerName] = server_entry(command)
  match document {
    Object(root) => {
      root["mcpServers"] = Json::object(servers)
      render_document(Json::object(root))
    }
    _ => render_document(document)
  }
}

///|
/// Remove our entry from a document, or `None` when it has none. An empty
/// `mcpServers` is left in place: removing a key the user may expect is worse than
/// an empty object.
pub fn remove_server(existing : String) -> String? raise {
  let document = parse_document(Some(existing))
  let servers = servers_of(document)
  if !servers.contains(ServerName) {
    return None
  }
  servers.remove(ServerName)
  match document {
    Object(root) => {
      root["mcpServers"] = Json::object(servers)
      Some(render_document(Json::object(root)))
    }
    _ => None
  }
}

///|
/// Whether `text` already carries our block.
pub fn has_agents_block(text : String) -> Bool {
  text.find(AgentsBegin) is Some(_) && text.find(AgentsEnd) is Some(_)
}

///|
/// Insert the block, or replace the existing one in place. Text outside the
/// markers is never touched.
pub fn upsert_agents_block(text : String, block : String) -> String {
  let begin = text.find(AgentsBegin)
  let end = text.find(AgentsEnd)
  match (begin, end) {
    (Some(begin), Some(end)) =>
      if end + AgentsEnd.length() >= text.length() {
        text[:begin].to_owned() + block
      } else {
        text[:begin].to_owned() +
        block +
        text[end + AgentsEnd.length():].to_owned()
      }
    _ =>
      if text.trim().is_empty() {
        block + "\n"
      } else {
        text.trim_end().to_owned() + "\n\n" + block + "\n"
      }
  }
}

///|
/// Remove the block, or `None` when there is none. Returns the remaining text,
/// which may be empty — the caller decides whether an empty file should exist.
pub fn remove_agents_block(text : String) -> String? {
  let begin = text.find(AgentsBegin)
  let end = text.find(AgentsEnd)
  match (begin, end) {
    (Some(begin), Some(end)) => {
      let before = text[:begin].to_owned()
      let after = if end + AgentsEnd.length() >= text.length() {
        ""
      } else {
        text[end + AgentsEnd.length():].to_owned()
      }
      Some((before + after).trim().to_owned())
    }
    _ => None
  }
}
