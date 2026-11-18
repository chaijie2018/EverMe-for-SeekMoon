// The four memory endpoints, in the shape the MCP server needs them. All of
// them are Bearer (`evt_`) calls: the agent is bound from the token, so no
// request names it.
//
// Clamping lives here as well as at the tool boundary: `query` is capped at the
// backend's limit and `topK` at the contract's ceiling, so a model that pastes a
// whole transcript or asks for 9999 results still gets an answer instead of a
// validation error.

///|
/// `POST /mem/search` unpacked: episodes arrive under `items`, with parallel
/// profile, transcript, and agent-memory arrays beside them.
pub(all) struct SearchBundle {
  memories : Array[Json]
  profiles : Array[Json]
  raw_messages : Array[Json]
  skills : Array[Json]
  cases : Array[Json]
  request_id : String
}

///|
/// `POST /mem/context` unpacked: either a pre-rendered block or a structured
/// profile the caller renders.
pub(all) struct ContextBundle {
  context : String
  profile : Json?
  memory_count : Int32
  request_id : String
}

///|
/// The backend's query cap (it counts runes; UTF-16 units are never fewer, so a
/// value clamped here always fits).
pub const QueryMaxChars : Int32 = 1024

///|
/// `topK` default, per the public contract.
pub const TopKDefault : Int32 = 10

///|
/// `topK` ceiling, per the public contract.
pub const TopKMax : Int32 = 50

///|
/// The gateway's per-request message cap for `/mem/agent-memory`.
pub const MaxMessagesPerRequest : Int32 = 500

///|
/// Trim a query and cap it at the backend's limit.
pub fn clamp_query(text : String) -> String {
  let trimmed = text.trim()
  if trimmed.length() > QueryMaxChars {
    trimmed[:QueryMaxChars].to_owned()
  } else {
    trimmed.to_owned()
  }
}

///|
/// A usable `topK`: non-positive falls back to the default, oversize is capped.
pub fn normalize_top_k(value : Int32) -> Int32 {
  if value <= 0 {
    TopKDefault
  } else if value > TopKMax {
    TopKMax
  } else {
    value
  }
}

///|
/// `name` of `arguments` as a `topK`, or the default when it is absent or not a
/// number. A model asking for a bad value gets a recall, not an error.
pub fn top_k_field(arguments : Json, name : String) -> Int32 {
  match arguments {
    Object(fields) =>
      match fields.get(name) {
        Some(Number(value, ..)) => normalize_top_k(value.to_int())
        _ => TopKDefault
      }
    _ => TopKDefault
  }
}

///|
/// `POST /mem/search`.
pub async fn Client::search(
  self : Client,
  query~ : String,
  top_k~ : Int32,
) -> SearchBundle raise ApiError {
  let exchange = self.request("/mem/search", {
    "query": Json(clamp_query(query)),
    "topK": Json(normalize_top_k(top_k)),
  })
  let result = exchange.envelope.result
  {
    memories: array_field(result, "items"),
    profiles: array_field(result, "profiles"),
    raw_messages: array_field(result, "rawMessages"),
    skills: nested_array_field(result, "agentMemory", "skills"),
    cases: nested_array_field(result, "agentMemory", "cases"),
    request_id: exchange.envelope.request_id,
  }
}

///|
/// `POST /mem/context` — the user's durable Profile, never a search.
pub async fn Client::context(
  self : Client,
  force_refresh~ : Bool,
) -> ContextBundle raise ApiError {
  let body : Json = if force_refresh {
    { "forceRefresh": true }
  } else {
    Json::empty_object()
  }
  let exchange = self.request("/mem/context", body)
  let result = exchange.envelope.result
  let profile = match result {
    Object(fields) =>
      match fields.get("profile") {
        Some(profile) => Some(profile)
        None => None
      }
    _ => None
  }
  {
    context: string_field(result, "context"),
    profile,
    memory_count: int_field(result, "memoryCount"),
    request_id: exchange.envelope.request_id,
  }
}

///|
/// `POST /mem/personal` — plain user/assistant turns, which is the path that
/// lands a stated fact in the profile.
pub async fn Client::save_personal(
  self : Client,
  conversation_id~ : String,
  messages~ : Array[Json],
  flush~ : Bool,
) -> (Json, String) raise ApiError {
  let exchange = self.request("/mem/personal", {
    "conversationId": Json(conversation_id),
    "messages": Json::array(messages),
    "flush": flush,
  })
  (exchange.envelope.result, exchange.envelope.request_id)
}

///|
/// `POST /mem/agent-memory` — a trajectory, split into batches the gateway
/// accepts. Only the last batch carries the caller's `flush`, so extraction sees
/// the complete session rather than a prefix.
pub async fn Client::save_agent_memory(
  self : Client,
  conversation_id~ : String,
  messages~ : Array[Json],
  flush~ : Bool,
) -> (Json, String) raise ApiError {
  let batch_count = if messages.is_empty() {
    1
  } else {
    (messages.length() + MaxMessagesPerRequest - 1) / MaxMessagesPerRequest
  }
  let mut last : Json = Json::null()
  let mut last_request_id = ""
  for batch in 0..<batch_count {
    let start = batch * MaxMessagesPerRequest
    let end = (start + MaxMessagesPerRequest).min(messages.length())
    let slice : Array[Json] = []
    for index in start..<end {
      slice.push(messages[index])
    }
    let is_last = batch + 1 == batch_count
    let body : Json = {
      "conversationId": Json(conversation_id),
      "messages": Json::array(slice),
      "flush": if is_last {
        flush
      } else {
        false
      },
    }
    let (result, request_id) = {
      let exchange = self.request("/mem/agent-memory", body)
      (exchange.envelope.result, exchange.envelope.request_id)
    }
    last = result
    last_request_id = request_id
  }
  (last, last_request_id)
}
