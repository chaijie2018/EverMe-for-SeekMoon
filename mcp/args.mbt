// Argument handling, kept away from the method table so the two can be read
// separately: everything here turns loose model-authored JSON into the exact
// shape the gateway accepts, and every failure is a sentence a model can act on.

///|
/// `name` of `json` as raw JSON, or `null`.
pub fn field(json : Json, name : String) -> Json {
  match json {
    Object(fields) =>
      match fields.get(name) {
        Some(value) => value
        None => Json::null()
      }
    _ => Json::null()
  }
}

///|
/// `name` of `json` as a string, or "".
pub fn text_field(json : Json, name : String) -> String {
  match field(json, name) {
    String(value) => value
    _ => ""
  }
}

///|
/// `name` of `json` as a bool, or `false`.
pub fn bool_field(json : Json, name : String) -> Bool {
  match field(json, name) {
    True => true
    _ => false
  }
}

///|
/// `name` of `json` as an array of values, or `[]`.
pub fn array_field(json : Json, name : String) -> Array[Json] {
  match field(json, name) {
    Array(values) => values
    _ => []
  }
}

///|
/// The conversation id, defaulting to `default` as upstream does.
pub fn session_key(arguments : Json) -> String {
  let key = text_field(arguments, "sessionKey").trim()
  if key.is_empty() {
    "default"
  } else {
    key.to_owned()
  }
}

///|
/// Whether to materialize now. Default true: a caller that forgets the flag should
/// not leave facts sitting as raw messages, which is upstream's documented
/// historical bug.
pub fn flush_field(arguments : Json) -> Bool {
  match field(arguments, "flush") {
    False => false
    _ => true
  }
}

///|
/// The first non-empty text among `names`.
fn first_text(json : Json, names : Array[String]) -> String {
  for name in names {
    let value = text_field(json, name)
    if !value.is_empty() {
      return value
    }
  }
  ""
}

///|
/// The tool calls a message carries, when it has any.
fn tool_calls_of(message : Json) -> Array[Json] {
  array_field(message, "toolCalls")
}

///|
/// Turn model-authored turns into the gateway's message shape: `role`, `content`,
/// and, where present, `toolCallId` / `toolCalls` / `timestamp`. Empty turns are
/// dropped rather than sent, because the gateway rejects content-less messages and
/// one bad row would fail the whole write.
///
/// `allow_tools` picks which roles are acceptable: the personal path is
/// user/assistant only, while a trajectory may carry tool results.
pub fn normalize_messages(
  raw : Array[Json],
  allow_tools~ : Bool,
) -> Result[Array[Json], String] {
  let out : Array[Json] = []
  for message in raw {
    let role = text_field(message, "role")
    let content = first_text(message, ["content", "text"])
    let tool_call_id = first_text(message, ["toolCallId", "tool_call_id"])
    let tool_calls = tool_calls_of(message)
    let role_ok = match role {
      "user" | "assistant" => true
      "tool" | "toolResult" => allow_tools
      _ => false
    }
    if !role_ok {
      if allow_tools {
        // A trajectory with an unexpected role is skipped, not rejected: the
        // rest of the round trip is still worth keeping.
        continue
      }
      return Err(
        "mem_save_fact accepts only 'user' or 'assistant' roles; got \"\{role}\". The personal-memory path does not record tool turns — use mem_save_turn for trajectories.",
      )
    }
    if content.is_empty() && tool_calls.is_empty() {
      continue
    }
    let fields : Map[String, Json] = Map([])
    fields["role"] = Json(if role == "toolResult" { "tool" } else { role })
    if !content.is_empty() {
      fields["content"] = Json(content)
    }
    if !tool_call_id.is_empty() {
      fields["toolCallId"] = Json(tool_call_id)
    }
    if !tool_calls.is_empty() {
      fields["toolCalls"] = Json::array(tool_calls)
    }
    // A caller-supplied timestamp is kept (it orders a replay); the gateway
    // stamps its own when absent, which is the ordinary live path.
    let timestamp = text_field(message, "timestamp")
    if !timestamp.is_empty() {
      fields["timestamp"] = Json(timestamp)
    }
    out.push(Json::object(fields))
  }
  if out.is_empty() {
    return Err("the messages carried no usable content")
  }
  Ok(out)
}

///|
/// The `messages` array of `arguments` (may be empty).
pub fn messages_arg(arguments : Json) -> Array[Json] {
  array_field(arguments, "messages")
}

///|
/// The single-turn shorthand (`role` + `text`) as a one-message array.
pub fn single_turn(arguments : Json) -> Array[Json] {
  let role = text_field(arguments, "role")
  let role = if role.is_empty() { "user" } else { role }
  let text = first_text(arguments, ["text", "content"])
  if text.is_empty() {
    return []
  }
  let fields : Map[String, Json] = Map([])
  fields["role"] = Json(role)
  fields["content"] = Json(text)
  let tool_call_id = text_field(arguments, "toolCallId")
  if !tool_call_id.is_empty() {
    fields["toolCallId"] = Json(tool_call_id)
  }
  [Json::object(fields)]
}
