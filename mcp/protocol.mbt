// The method table, as a pure function: given one decoded JSON-RPC message,
// decide what to answer and, when the answer needs the backend, hand back an
// `Action` for the caller to execute.
//
// Keeping the decision pure is what makes this layer testable without a network
// or a subprocess: every arm — handshake, tool call, resource read, a method we
// do not implement — is checked by feeding JSON in and reading the `Decision`
// out. The parts that need IO (HTTP, stdio) live in `execute` and `serve`.

///|
/// Work for the backend, with arguments already validated and normalized.
pub(all) enum Action {
  /// `mem_context` — the durable profile.
  Context(force_refresh~ : Bool)
  /// `mem_search`.
  Search(query~ : String, top_k~ : Int32)
  /// `mem_save_fact` — user/assistant turns only.
  SaveFact(messages~ : Array[Json], session_key~ : String, flush~ : Bool)
  /// `mem_save_turn` — a trajectory, tool turns allowed.
  SaveTurn(messages~ : Array[Json], session_key~ : String, flush~ : Bool)
  /// `mem://profile`.
  Profile
  /// `mem://search?…`.
  SearchResource(query~ : String, top_k~ : Int32)
}

///|
/// What to do with one message.
pub(all) enum Decision {
  /// Nothing to answer (a notification, or a response to a request we never send).
  Nothing
  /// A result this server can produce without the backend.
  Answer(id~ : Json, result~ : Json)
  /// A JSON-RPC error this server can produce without the backend.
  Fail(id~ : Json, code~ : Int32, message~ : String)
  /// Work for the backend. `as_tool` picks the failure shape: a tool call reports
  /// failures as `isError` content, a resource read as a JSON-RPC error.
  Perform(id~ : Json, action~ : Action, as_tool~ : Bool)
}

///|
/// JSON-RPC method-not-found. Deliberately outside MCP's stateless-peer range
/// (`-32020`..`-32022`), so a client probing `server/discover` falls back to the
/// legacy handshake instead of treating us as a stateless server.
pub const CodeMethodNotFound : Int32 = -32601

///|
/// JSON-RPC invalid-params.
pub const CodeInvalidParams : Int32 = -32602

///|
/// JSON-RPC internal error, used when a backend call fails during a resource read.
pub const CodeInternal : Int32 = -32603

///|
/// JSON-RPC parse error.
pub const CodeParseError : Int32 = -32700

///|
/// A tool result carrying markdown/text.
pub fn tool_text(text : String) -> Json {
  { "content": Json::array([{ "type": "text", "text": Json(text) }]) }
}

///|
/// A tool result that failed, which is a tool error rather than a protocol error.
pub fn tool_error(text : String) -> Json {
  {
    "content": Json::array([{ "type": "text", "text": Json(text) }]),
    "isError": true,
  }
}

///|
/// A resource read result.
pub fn resource_text(uri : String, text : String) -> Json {
  {
    "contents": Json::array([
      { "uri": Json(uri), "mimeType": "text/markdown", "text": Json(text) },
    ]),
  }
}

///|
/// A JSON-RPC success reply.
pub fn reply(id : Json, result : Json) -> Json {
  { "jsonrpc": "2.0", "id": id, "result": result }
}

///|
/// A JSON-RPC error reply.
pub fn error_reply(id : Json, code : Int32, message : String) -> Json {
  {
    "jsonrpc": "2.0",
    "id": id,
    "error": { "code": Json(code), "message": Json(message) },
  }
}

///|
/// A reply to a message whose id could not even be read.
pub fn parse_error_reply(message : String) -> Json {
  error_reply(Json::null(), CodeParseError, message)
}

///|
/// The `initialize` result. The protocol version is echoed when the client names
/// one: MCP negotiates by the client's version, and a server that invents one is
/// simply disconnected by strict clients.
fn initialize_result(params : Json) -> Json {
  let requested = text_field(params, "protocolVersion")
  let version = if requested.is_empty() { "2024-11-05" } else { requested }
  {
    "protocolVersion": Json(version),
    "capabilities": {
      "tools": Json::empty_object(),
      "resources": Json::empty_object(),
    },
    "serverInfo": { "name": "everme-memory", "version": Json(@config.Version) },
    "instructions": Json(instructions()),
  }
}

///|
/// `tools/call`.
fn decide_tool_call(id : Json, params : Json) -> Decision {
  let name = text_field(params, "name")
  let arguments = match field(params, "arguments") {
    Object(_) => field(params, "arguments")
    _ => Json::empty_object()
  }
  match name {
    "" => Answer(id~, result=tool_error("tools/call requires a tool `name`"))
    "mem_context" =>
      Perform(
        id~,
        action=Context(force_refresh=bool_field(arguments, "forceRefresh")),
        as_tool=true,
      )
    "mem_search" => {
      let query = @api.clamp_query(text_field(arguments, "query"))
      if query.is_empty() {
        Answer(
          id~,
          result=tool_error("mem_search requires a non-empty `query`"),
        )
      } else {
        Perform(
          id~,
          action=Search(query~, top_k=@api.top_k_field(arguments, "topK")),
          as_tool=true,
        )
      }
    }
    "mem_save_fact" => decide_save_fact(id, arguments)
    "mem_save_turn" => decide_save_turn(id, arguments)
    other => Answer(id~, result=tool_error("unknown tool: \{other}"))
  }
}

///|
/// `mem_save_fact`: `messages[]` (user/assistant only) or the `fact` shorthand.
fn decide_save_fact(id : Json, arguments : Json) -> Decision {
  let mut raw = messages_arg(arguments)
  if raw.is_empty() {
    let fact = text_field(arguments, "fact")
    if fact.trim().is_empty() {
      return Answer(
        id~,
        result=tool_error(
          "mem_save_fact requires either `fact` or a non-empty `messages` array",
        ),
      )
    }
    let message : Map[String, Json] = Map([])
    message["role"] = Json("user")
    message["content"] = Json(fact)
    raw = [Json::object(message)]
  }
  match normalize_messages(raw, allow_tools=false) {
    Ok(messages) =>
      Perform(
        id~,
        action=SaveFact(
          messages~,
          session_key=session_key(arguments),
          flush=flush_field(arguments),
        ),
        as_tool=true,
      )
    Err(message) => Answer(id~, result=tool_error(message))
  }
}

///|
/// `mem_save_turn`: `messages[]` or the `role` + `text` shorthand.
fn decide_save_turn(id : Json, arguments : Json) -> Decision {
  let mut raw = messages_arg(arguments)
  if raw.is_empty() {
    raw = single_turn(arguments)
  }
  if raw.is_empty() {
    return Answer(
      id~,
      result=tool_error(
        "mem_save_turn requires `messages`, or `role` plus `text`",
      ),
    )
  }
  match normalize_messages(raw, allow_tools=true) {
    Ok(messages) =>
      Perform(
        id~,
        action=SaveTurn(
          messages~,
          session_key=session_key(arguments),
          flush=flush_field(arguments),
        ),
        as_tool=true,
      )
    Err(message) => Answer(id~, result=tool_error(message))
  }
}

///|
/// `resources/read`.
fn decide_resource_read(id : Json, params : Json) -> Decision {
  let uri = text_field(params, "uri")
  if uri == "mem://profile" {
    return Perform(id~, action=Profile, as_tool=false)
  }
  match parse_search_uri(uri) {
    Some(search) =>
      if search.query.is_empty() {
        Fail(
          id~,
          code=CodeInvalidParams,
          message="mem://search requires a non-empty 'q' parameter; got URI: \{uri}",
        )
      } else {
        Perform(
          id~,
          action=SearchResource(query=search.query, top_k=search.top_k),
          as_tool=false,
        )
      }
    None =>
      Fail(
        id~,
        code=CodeInvalidParams,
        message="unknown resource uri: \{uri} (supported: mem://profile, mem://search?q=…)",
      )
  }
}

///|
/// Decide what one message means.
pub fn decide(message : Json) -> Decision {
  let verb = text_field(message, "method")
  if verb.is_empty() {
    // A response to a request this server never sends.
    return Nothing
  }
  if verb.has_prefix("notifications/") {
    return Nothing
  }
  let id = field(message, "id")
  let params = field(message, "params")
  match verb {
    "initialize" => Answer(id~, result=initialize_result(params))
    "ping" => Answer(id~, result=Json::empty_object())
    "tools/list" => Answer(id~, result={ "tools": Json::array(tool_schemas()) })
    "tools/call" => decide_tool_call(id, params)
    "resources/list" =>
      Answer(id~, result={ "resources": Json::array([profile_resource()]) })
    "resources/templates/list" =>
      Answer(id~, result={
        "resourceTemplates": Json::array([search_template()]),
      })
    "resources/read" => decide_resource_read(id, params)
    // Includes `server/discover`: answering method-not-found is what makes a
    // stateless-aware client fall back to `initialize`.
    other =>
      Fail(id~, code=CodeMethodNotFound, message="Method not found: \{other}")
  }
}
