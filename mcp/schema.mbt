// The tool surface this server advertises, plus the server-level instructions
// that tell a model when to reach for it. Names, resource URIs, and the meaning
// of each result are the upstream contract (`docs/contracts.md`); the wording
// here is ours, kept short because both descriptions and instructions land in the
// model's context.

///|
/// One tool entry: name, description, and a JSON Schema for its arguments.
fn tool(name : String, description : String, schema : Json) -> Json {
  {
    "name": Json(name),
    "description": Json(description),
    "inputSchema": schema,
  }
}

///|
/// A schema object with `properties`, closing it to unknown fields.
fn object_schema(properties : Json) -> Json {
  { "type": "object", "properties": properties, "additionalProperties": false }
}

///|
/// `{type: <type>, description: <text>}`.
fn property(kind : String, description : String) -> Json {
  { "type": Json(kind), "description": Json(description) }
}

///|
/// The four memory tools, in the order they are listed.
pub fn tool_schemas() -> Array[Json] {
  [
    tool(
      "mem_context",
      "Return the user's durable EverMe Profile only — no semantic search, no episodes, no raw transcript. Call it once at the start of a session; pass forceRefresh:true only when the user explicitly asks to refresh the profile.",
      object_schema({
        "forceRefresh": property(
          "boolean", "Re-fetch the profile instead of using the server's cached copy.",
        ),
      }),
    ),
    tool(
      "mem_search",
      "Semantic search across the user's EverMe memories: episodes, profile entries, agent cases and skills, and recent transcript. Use it when the user refers to earlier conversations, decisions, conventions, or previously solved problems. Keep `query` to a few keywords — never paste a whole conversation — and do not repeat an identical query within one turn.",
      object_schema({
        "query": property("string", "Short keyword query."),
        "topK": property(
          "integer", "Maximum rows to return (default 10, capped at 50).",
        ),
      }),
    ),
    tool(
      "mem_save_fact",
      "Record a durable fact about the user — a preference, habit, trait, long-term goal, or decision — without waiting to be asked. Only user/assistant turns are accepted. The result's extracted/profileUpdated is the only proof the profile actually updated: on no_extraction say so plainly instead of claiming it was remembered.",
      object_schema({
        "fact": property("string", "The fact, as one user statement."),
        "messages": property(
          "array", "User/assistant turns carrying the fact; takes precedence over `fact`.",
        ),
        "sessionKey": property(
          "string", "Conversation id; use one stable value per chat.",
        ),
        "flush": property(
          "boolean", "Materialize now (default true); false keeps it append-only.",
        ),
      }),
    ),
    tool(
      "mem_save_turn",
      "Record how a task was solved, as a trajectory: user → assistant tool calls → tool results → final answer. It feeds episodic, agent-case, and agent-skill extraction. Use mem_save_fact for a stated preference instead of relying on the derived transcript.",
      object_schema({
        "messages": property(
          "array", "Turns to record: role is user, assistant, or tool.",
        ),
        "role": property("string", "Single-turn form: the role."),
        "text": property("string", "Single-turn form: the text."),
        "toolCallId": property(
          "string", "Single-turn form: the tool call this result answers.",
        ),
        "sessionKey": property(
          "string", "Conversation id; use one stable value per chat.",
        ),
        "flush": property("boolean", "Materialize now (default true)."),
      }),
    ),
  ]
}

///|
/// The one static resource: the profile.
pub fn profile_resource() -> Json {
  {
    "uri": "mem://profile",
    "name": "EverMe profile",
    "description": "The user's durable profile and relevant context (markdown).",
    "mimeType": "text/markdown",
  }
}

///|
/// The parameterised search resource.
pub fn search_template() -> Json {
  {
    "uriTemplate": "mem://search?q={query}&topK={topK}",
    "name": "EverMe memory search",
    "description": "Semantic search over the user's memories (markdown).",
    "mimeType": "text/markdown",
  }
}

///|
/// What the server tells a host about itself at `initialize`. A condensed
/// version of upstream's instructions: the order matters, because the first rule
/// is what keeps a session from re-fetching the profile on every turn.
pub fn instructions() -> String {
  let text =
    #|EverMe gives this agent the user's personal memory, shared across their devices and agents.
    #|
    #|1. Start of a session — if the host has not already injected a profile block, call `mem_context` once. It returns the durable Profile only (no search, no episodes, no transcript). Do not fetch it again later unless the user asks to refresh.
    #|2. The user states a durable fact about themselves (preference, habit, trait, long-term goal, decision) — call `mem_save_fact` immediately, without being asked. Only `extracted:true` / `profileUpdated:true` means the profile really updated; on `no_extraction` do not claim it was remembered.
    #|3. A task was solved in a way worth reusing — call `mem_save_turn` with the complete trajectory (user → assistant tool calls → tool results → answer). It feeds episodic, case, and skill extraction.
    #|4. The user references earlier conversations, decisions, conventions, or solved problems — call `mem_search` with a SHORT query. Skip it when the host already injected relevant recall this turn, and never repeat an identical query in one turn.
    #|
    #|Resources: `mem://profile` (profile only) and `mem://search?q={query}&topK={topK}`. Saving has no resource equivalent. Rows under the provisional unextracted-transcript header are not yet extracted — never quote them as established facts.
  text
}
