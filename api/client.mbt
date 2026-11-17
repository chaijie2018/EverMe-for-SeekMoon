// The EverMe HTTP client: one bounded POST helper, one envelope check, and a
// typed method per endpoint P1 needs. Every call is bounded (30s) so a wedged
// gateway becomes a failure instead of a hang, and every failure keeps the
// backend's own `error` text plus its `requestId` — that is what makes
// `doctor --probe-platform` useful instead of guesswork.

///|
/// Deadline for one HTTP exchange. Upstream uses the same 30s for memory calls.
const RequestTimeoutMs : Int32 = 30000

///|
/// The user agent this build reports, so backend audit logs can tell it apart
/// from `evercli` and from the Node MCP server.
const UserAgent : String = "everme-cli/0.1.0 (seekmoon)"

///|
/// Honestly, a client is just a base URL and the token to present. The token is
/// empty for the unauthenticated auth endpoints.
pub(all) struct Client {
  base : String
  token : String
}

///|
/// A client for `base` (already normalized to `…/api/v1`), unauthenticated.
pub fn Client::new(base~ : String) -> Client {
  { base, token: "", }
}

///|
/// The same client, now presenting `token` as a Bearer credential.
pub fn Client::with_token(self : Client, token : String) -> Client {
  { base: self.base, token, }
}

///|
/// The API root this client posts to (used in diagnostics).
pub fn Client::base(self : Client) -> String {
  self.base
}

///|
/// POST `body` to `path` with no interpretation of the result: the HTTP status
/// and the raw body come back even for an error status. Raises only when the
/// exchange itself failed (transport, TLS, timeout).
async fn raw_post(
  client : Client,
  path : String,
  body : Json,
) -> (Int32, String) raise ApiError {
  let headers : @http.Headers = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "User-Agent": UserAgent,
  }
  if !client.token.is_empty() {
    headers["Authorization"] = "Bearer \{client.token}"
  }
  let url = client.base + path
  let payload = body.stringify()
  let attempt = () => @http.post_text(url, payload, headers~)
  let outcome = @async.with_timeout_opt(RequestTimeoutMs, attempt) catch {
    error => raise ApiError(network_failure("\{error}"))
  }
  match outcome {
    Some((response, text)) => (response.code, text)
    None =>
      raise ApiError(
        network_failure(
          "no answer from \{url} within \{RequestTimeoutMs / 1000}s",
        ),
      )
  }
}

///|
/// One exchange, decoded: never raises for a non-2xx status or a failed
/// envelope. This is what a probe wants — the raw truth, not a verdict.
pub async fn Client::attempt(
  self : Client,
  path : String,
  body : Json,
) -> Exchange raise ApiError {
  let (http_status, text) = raw_post(self, path, body)
  let envelope = decode_envelope(text, http_status)
  { http_status, envelope, }
}

///|
/// One exchange that must succeed: a non-2xx status or a non-zero envelope
/// status raises the classified failure.
pub async fn Client::request(
  self : Client,
  path : String,
  body : Json,
) -> Exchange raise ApiError {
  let exchange = self.attempt(path, body)
  if exchange.http_status >= 300 || !exchange.envelope.is_ok() {
    raise ApiError(failure_of(exchange))
  }
  exchange
}

///|
/// `POST /auth/login` — validate an `emk_` and return what it belongs to.
pub async fn Client::login(
  self : Client,
  api_key : String,
) -> LoginInfo raise ApiError {
  let exchange = self.request("/auth/login", { "apiKey": Json(api_key) })
  let result = exchange.envelope.result
  let info = {
    valid: bool_field(result, "valid"),
    account_id: string_field(result, "accountId"),
    email: string_field(result, "email"),
    api_key_prefix: string_field(result, "apiKeyPrefix"),
    scopes: strings_field(result, "scopes"),
  }
  if !info.valid {
    raise ApiError({
      kind: "auth",
      message: "the API key is not valid",
      hint: hint_for("auth"),
      http_status: exchange.http_status,
      code: exchange.envelope.status,
      request_id: exchange.envelope.request_id,
    })
  }
  info
}

///|
/// `POST /auth/device` — start a device-flow grant.
pub async fn Client::device_start(
  self : Client,
  platform~ : String,
  client_name~ : String,
  client_version~ : String,
  fingerprint~ : String,
) -> DeviceStart raise ApiError {
  let exchange = self.request("/auth/device", {
    "clientName": Json(client_name),
    "clientVersion": Json(client_version),
    "platform": Json(platform),
    "machineFingerprint": Json(fingerprint),
  })
  let result = exchange.envelope.result
  {
    device_code: string_field(result, "deviceCode"),
    user_code: string_field(result, "userCode"),
    verification_url: string_field(result, "verificationUrl"),
    expires_in: int_field(result, "expiresIn"),
    interval: int_field(result, "interval"),
  }
}

///|
/// `POST /auth/token` — poll a device-flow grant once.
pub async fn Client::device_token(
  self : Client,
  device_code : String,
) -> DeviceToken raise ApiError {
  let exchange = self.request("/auth/token", {
    "deviceCode": Json(device_code),
    "grantType": "device_code",
  })
  let result = exchange.envelope.result
  {
    status: string_field(result, "status"),
    api_key: string_field(result, "apiKey"),
    agent_token: string_field(result, "agentToken"),
    agent_id: string_field(result, "agentId"),
    interval: int_field(result, "interval"),
  }
}

///|
/// `POST /agents/list` — the agents this account already registered for
/// `platform` on this machine, so a re-install can reuse one instead of
/// minting another.
pub async fn Client::list_agents(
  self : Client,
  platform~ : String,
  fingerprint~ : String,
) -> Array[Json] raise ApiError {
  let exchange = self.request("/agents/list", {
    "platform": Json(platform),
    "machineFingerprint": Json(fingerprint),
  })
  match exchange.envelope.result {
    Object(fields) =>
      match fields.get("items") {
        Some(Array(items)) => items
        _ => []
      }
    _ => []
  }
}

///|
/// `POST /agents` — register (or claim) this machine's agent slot for
/// `platform` and receive its `evt_` token.
pub async fn Client::register_agent(
  self : Client,
  platform~ : String,
  name~ : String,
  client_version~ : String,
  fingerprint~ : String,
) -> AgentInfo raise ApiError {
  let exchange = self.request("/agents", {
    "platform": Json(platform),
    "name": Json(name),
    "clientVersion": Json(client_version),
    "machineFingerprint": Json(fingerprint),
  })
  let result = exchange.envelope.result
  {
    agent_id: string_field(result, "agentId"),
    agent_token: string_field(result, "agentToken"),
    token_prefix: string_field(result, "tokenPrefix"),
    source_id: string_field(result, "sourceId"),
  }
}

///|
/// `POST /agents/disconnect` — retire one of this account's agents. Used to
/// clean up an agent this CLI registered under a label it no longer wants, so
/// the account's agent list keeps telling the truth.
pub async fn Client::disconnect_agent(
  self : Client,
  agent_id : String,
) -> Unit raise ApiError {
  ignore(self.request("/agents/disconnect", { "agentId": Json(agent_id) }))
}
