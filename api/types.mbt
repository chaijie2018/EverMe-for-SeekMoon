// The types the EverMe HTTP surface exchanges with this CLI: the response
// envelope, the failure taxonomy, and the decoded shapes of the endpoints P1
// uses (auth, devices, agents). Decoding is total: a field that is missing or
// the wrong type becomes "" or 0 rather than a crash, and the raw envelope is
// always kept so `doctor` can print what the backend actually said.

///|
/// A failure, shaped for both the JSON error envelope and the terminal.
/// `kind` follows the EverMe `error.type` taxonomy so scripts that already
/// handle `evercli` keep working.
pub(all) struct Failure {
  kind : String
  message : String
  hint : String
  http_status : Int32
  code : Int32
  request_id : String
}

///|
/// A request that did not succeed, either at the transport level or because
/// the backend's envelope reported a non-zero status.
pub(all) suberror ApiError {
  ApiError(Failure)
}

///|
/// The backend's `{error, requestId, status, result}` envelope. `status == 0`
/// is success; anything else carries the backend's own message in `error`.
pub(all) struct Envelope {
  status : Int32
  error : String
  request_id : String
  result : Json
}

///|
/// Whether the envelope reported success.
pub fn Envelope::is_ok(self : Envelope) -> Bool {
  self.status == 0
}

///|
/// One exchange: the HTTP status plus whatever envelope body came back. The
/// HTTP status is kept separately because a proxy or gateway can answer
/// without the envelope shape at all.
pub(all) struct Exchange {
  http_status : Int32
  envelope : Envelope
}

///|
/// `POST /auth/device` — a device-flow grant to show the user.
pub(all) struct DeviceStart {
  device_code : String
  user_code : String
  verification_url : String
  expires_in : Int32
  interval : Int32
}

///|
/// One `POST /auth/token` poll. `status` is `pending`, `approved`, or
/// `expired`; the credential fields are filled only on approval.
pub(all) struct DeviceToken {
  status : String
  api_key : String
  agent_token : String
  agent_id : String
  interval : Int32
}

///|
/// What an `emk_` belongs to, per `POST /auth/login`.
pub(all) struct LoginInfo {
  valid : Bool
  account_id : String
  email : String
  api_key_prefix : String
  scopes : Array[String]
}

///|
/// A freshly minted agent, per `POST /agents`.
pub(all) struct AgentInfo {
  agent_id : String
  agent_token : String
  token_prefix : String
  source_id : String
}

///|
/// Read a string field of a JSON object, or "" when absent or not a string.
pub fn string_field(json : Json, field : String) -> String {
  match json {
    Object(fields) =>
      match fields.get(field) {
        Some(String(value)) => value
        _ => ""
      }
    _ => ""
  }
}

///|
/// Read a number field of a JSON object, or 0 when absent or not a number.
pub fn int_field(json : Json, field : String) -> Int32 {
  match json {
    Object(fields) =>
      match fields.get(field) {
        Some(Number(value, ..)) => value.to_int()
        _ => 0
      }
    _ => 0
  }
}

///|
/// Read a bool field of a JSON object, or `false` when absent or not a bool.
pub fn bool_field(json : Json, field : String) -> Bool {
  match json {
    Object(fields) =>
      match fields.get(field) {
        Some(True) => true
        _ => false
      }
    _ => false
  }
}

///|
/// Read a string array field, dropping non-string members.
pub fn strings_field(json : Json, field : String) -> Array[String] {
  match json {
    Object(fields) =>
      match fields.get(field) {
        Some(Array(values)) =>
          values.filter_map(value => {
            match value {
              String(text) => Some(text)
              _ => None
            }
          })
        _ => []
      }
    _ => []
  }
}

///|
/// Read an array field as JSON values, or `[]` when absent or not an array.
pub fn array_field(json : Json, field : String) -> Array[Json] {
  match json {
    Object(fields) =>
      match fields.get(field) {
        Some(Array(values)) => values
        _ => []
      }
    _ => []
  }
}

///|
/// Read `outer.inner` as an array, or `[]`.
pub fn nested_array_field(
  json : Json,
  outer : String,
  inner : String,
) -> Array[Json] {
  match json {
    Object(fields) =>
      match fields.get(outer) {
        Some(value) => array_field(value, inner)
        None => []
      }
    _ => []
  }
}

///|
/// Decode the envelope body. A body that is not JSON at all — an HTML error
/// page from a proxy, say — is reported with a bounded, redacted excerpt
/// rather than as a parse crash.
pub fn decode_envelope(
  text : String,
  http_status : Int32,
) -> Envelope raise ApiError {
  let json = @json.parse(text) catch {
    _ => {
      let excerpt = @redact.mask(text[:400].to_owned())
      raise ApiError({
        kind: "upstream",
        message: "the endpoint answered HTTP \{http_status} with a non-JSON body: \{excerpt}",
        hint: "check the API base (EVERME_API_BASE) and that the gateway is up",
        http_status,
        code: 0,
        request_id: "",
      })
    }
  }
  {
    status: int_field(json, "status"),
    error: string_field(json, "error"),
    request_id: string_field(json, "requestId"),
    result: match json {
      Object(fields) =>
        match fields.get("result") {
          Some(result) => result
          None => Json::null()
        }
      _ => Json::null()
    },
  }
}

///|
/// Classify an HTTP status into the `error.type` taxonomy.
pub fn classify(http_status : Int32) -> String {
  if http_status == 401 || http_status == 403 {
    "auth"
  } else if http_status == 404 {
    "not_found"
  } else if http_status == 409 {
    "conflict"
  } else if http_status == 429 {
    "rate_limit"
  } else if http_status >= 500 {
    "upstream"
  } else if http_status >= 400 {
    "invalid_args"
  } else {
    "upstream"
  }
}

///|
/// A hint that names the next action for each failure kind.
pub fn hint_for(kind : String) -> String {
  match kind {
    "auth" =>
      "run `everme auth login` (or `everme auth adopt-evercli`) to refresh the credential"
    "not_logged_in" => "run `everme auth login` first"
    "rate_limit" => "wait a moment and retry"
    "network" => "check connectivity and EVERME_API_BASE"
    "invalid_args" => "the backend rejected a field; see the message above"
    "not_found" => "the endpoint or resource does not exist"
    "conflict" => "the resource already exists or changed underneath this call"
    _ => "see the message above"
  }
}

///|
/// Turn a failed exchange into the failure this CLI reports.
pub fn failure_of(exchange : Exchange) -> Failure {
  let envelope = exchange.envelope
  let kind = if exchange.http_status >= 400 {
    classify(exchange.http_status)
  } else {
    "upstream"
  }
  let message = if envelope.error.is_empty() || envelope.error == "ok" {
    "the backend reported status \{envelope.status} for HTTP \{exchange.http_status}"
  } else {
    envelope.error
  }
  {
    kind,
    message: @redact.mask(message),
    hint: hint_for(kind),
    http_status: exchange.http_status,
    code: envelope.status,
    request_id: envelope.request_id,
  }
}

///|
/// A transport-level failure (DNS, connection, TLS, timeout).
pub fn network_failure(message : String) -> Failure {
  {
    kind: "network",
    message: @redact.mask(message),
    hint: hint_for("network"),
    http_status: 0,
    code: 0,
    request_id: "",
  }
}
