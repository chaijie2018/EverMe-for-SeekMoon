// Reading a SeekMoon session log into the turns EverMe wants.
//
// A session file is one JSON header line followed by append-only records:
//
//   {"version":1,"id":"…","system_prompt":"…"}
//   {"sequence":1,"ts":1794914457386,"item":{"kind":"user","payload":{"content":"…"}}}
//   {"sequence":2,…,"item":{"kind":"assistant","payload":{"content":"","tool_calls":[…]}}}
//   {"sequence":3,…,"item":{"kind":"tool_result","payload":{"tool_call_id":"…","tool_name":"…","content":"…"}}}
//
// Only user, assistant, and tool_result carry conversation. `runtime_notice` and
// `terminal` are harness noise, and importing them would teach the memory engine
// that the user said things they never said.

///|
/// How much of one turn we keep. Tool results can be whole build logs; the memory
/// engine extracts facts and trajectories, not logs, and an unbounded payload
/// would blow the gateway's per-request budget.
const TurnMaxChars : Int32 = 8000

///|
/// One conversation turn, already reduced to what the gateway takes.
pub(all) struct Turn {
  sequence : Int32
  role : String
  content : String
  tool_call_id : String
  tool_calls : Array[Json]
  timestamp : Int64
}

///|
/// `text` capped at `TurnMaxChars`, with a marker when it was cut.
fn cap(text : String) -> String {
  if text.length() <= TurnMaxChars {
    return text
  }
  text[:TurnMaxChars].to_owned() + "…(truncated on import)"
}

///|
/// `name` of `json` as a string, or "".
fn text_of(json : Json, name : String) -> String {
  match json {
    Object(fields) =>
      match fields.get(name) {
        Some(String(value)) => value
        _ => ""
      }
    _ => ""
  }
}

///|
/// `name` of `json` as an integer, or 0.
fn int_of(json : Json, name : String) -> Int64 {
  match json {
    Object(fields) =>
      match fields.get(name) {
        Some(Number(value, ..)) => value.to_int64()
        _ => 0
      }
    _ => 0
  }
}

///|
/// The tool calls of one assistant turn, in the gateway's shape:
/// `{id, type, name, arguments}`, with `arguments` kept as the JSON text the model
/// produced (the gateway stores it verbatim).
fn tool_calls_of(payload : Json) -> Array[Json] {
  let raw = match payload {
    Object(fields) =>
      match fields.get("tool_calls") {
        Some(Array(calls)) => calls
        _ => []
      }
    _ => []
  }
  let calls : Array[Json] = []
  for call in raw {
    let id = text_of(call, "id")
    if id.is_empty() {
      continue
    }
    let name = text_of(call, "name")
    let arguments = match call {
      Object(fields) =>
        match fields.get("arguments") {
          Some(String(text)) => text
          Some(other) => other.stringify()
          None => "{}"
        }
      _ => "{}"
    }
    calls.push({
      "id": Json(id),
      "type": "function",
      "name": Json(name),
      "arguments": Json(arguments),
    })
  }
  calls
}

///|
/// Parse one session log into turns, skipping the header, unknown kinds, and
/// empty rows.
pub fn parse_turns(text : String) -> Array[Turn] {
  let turns : Array[Turn] = []
  for line in text.split("\n") {
    if line.trim().is_empty() {
      continue
    }
    let record : Json = @json.parse(line) catch { _ => continue }
    let payload = match record {
      Object(fields) =>
        match fields.get("item") {
          Some(Object(item)) =>
            match item.get("payload") {
              Some(Object(payload)) => Json::object(payload)
              _ => continue
            }
          _ => continue
        }
      _ => continue
    }
    let kind = text_of(
      match record {
        Object(fields) =>
          match fields.get("item") {
            Some(item) => item
            None => Json::null()
          }
        _ => Json::null()
      },
      "kind",
    )
    let role = match kind {
      "user" => "user"
      "assistant" => "assistant"
      "tool_result" => "tool"
      _ => continue
    }
    let tool_calls = if role == "assistant" {
      tool_calls_of(payload)
    } else {
      []
    }
    // An assistant turn may legitimately carry only tool calls; an empty
    // user/tool turn carries nothing worth sending.
    let content = cap(text_of(payload, "content"))
    let brief = if role == "assistant" {
      cap(text_of(payload, "brief"))
    } else {
      ""
    }
    let content = if content.is_empty() { brief } else { content }
    if content.trim().is_empty() && tool_calls.is_empty() {
      continue
    }
    let tool_call_id = text_of(payload, "tool_call_id")
    let mut timestamp = int_of(record, "ts")
    if timestamp == 0 {
      timestamp = int_of(payload, "ts")
    }
    turns.push({
      sequence: int_of(record, "sequence").to_int(),
      role,
      content,
      tool_call_id,
      tool_calls,
      timestamp,
    })
  }
  turns
}

///|
/// One turn in the gateway's message shape.
pub fn message_of(turn : Turn) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["role"] = Json(turn.role)
  if !turn.content.is_empty() {
    fields["content"] = Json(turn.content)
  }
  if !turn.tool_call_id.is_empty() {
    fields["toolCallId"] = Json(turn.tool_call_id)
  }
  if !turn.tool_calls.is_empty() {
    fields["toolCalls"] = Json::array(turn.tool_calls)
  }
  if turn.timestamp > 0 {
    fields["timestamp"] = Json::number(turn.timestamp.to_double())
  }
  Json::object(fields)
}

///|
/// The conversation id a session maps to: stable, and namespaced so a session id
/// can never collide with another host's conversation.
pub fn conversation_id(session_id : String) -> String {
  "openseek:\{session_id}"
}

///|
/// The turns at or after `next_sequence` (0 means "everything").
pub fn since(turns : Array[Turn], next_sequence : Int32) -> Array[Turn] {
  if next_sequence <= 0 {
    return turns
  }
  let out : Array[Turn] = []
  for turn in turns {
    if turn.sequence >= next_sequence {
      out.push(turn)
    }
  }
  out
}

///|
/// The highest sequence in `turns`, or `fallback` when there is none — the cursor
/// to store after a successful import.
pub fn last_sequence(turns : Array[Turn], fallback : Int32) -> Int32 {
  let mut last = fallback
  for turn in turns {
    if turn.sequence > last {
      last = turn.sequence
    }
  }
  last
}
