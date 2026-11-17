// Registering this machine's agent is the step the backend can refuse by
// *value*: it validates `platform` against its own `known_platform` enum, and
// `seekmoon` is not in it (HTTP 400, `status=20004`,
// "platform: seekmoon does not validate as known_platform").
//
// So the label is negotiated, not assumed: try the one we want, and only when
// the backend rejects that value retry with a neutral label — `evercli`, the
// one upstream's own CLI registers, which reads as "some command-line client"
// rather than impersonating a specific product.
//
// What is never negotiated is the identity: every accepted attempt is our own
// `POST /agents`, minting our own agent and our own token. Borrowing another
// agent's token would file this CLI's memories under that agent (see design
// §12.2), which is why `adopt-evercli` takes only the account key.

///|
/// One registration attempt, kept so the report can show every label tried and
/// exactly what the backend said about each.
pub(all) struct Attempt {
  platform : String
  accepted : Bool
  http_status : Int32
  status : Int32
  error : String
  request_id : String
}

///|
/// What an accepted registration produced: the agent and its token.
pub(all) struct Registered {
  platform : String
  agent_id : String
  agent_token : String
  token_prefix : String
}

///|
/// Whether an envelope-carrying exchange succeeded.
pub fn exchange_ok(exchange : @api.Exchange) -> Bool {
  exchange.http_status < 300 && exchange.envelope.is_ok()
}

///|
/// The labels to try, in order, without blanks or repeats.
pub fn platform_candidates(
  desired : String,
  fallback : String,
) -> Array[String] {
  let candidates : Array[String] = []
  for label in [desired, fallback] {
    if !label.is_empty() && !candidates.contains(label) {
      candidates.push(label)
    }
  }
  candidates
}

///|
/// Whether a rejection is about the label's value, and so worth retrying under
/// another one. A network failure, a bad credential, or a 5xx would fail
/// identically under every label — retrying there would only hide the cause.
pub fn label_rejected(failure : @api.Failure) -> Bool {
  failure.kind == "invalid_args"
}

///|
/// Register this machine's agent under `desired`, falling back to `fallback`
/// only on a value rejection. Returns every attempt plus the accepted one.
/// Raises the failure that stopped the search: a non-value failure immediately
/// (so a network problem is not disguised as a platform problem), or the last
/// rejection when no label was accepted.
pub async fn register_with_fallback(
  client : @api.Client,
  fingerprint : String,
  desired : String,
  fallback : String,
  name : String,
) -> (Array[Attempt], Registered) {
  let attempts : Array[Attempt] = []
  let mut registered : Registered? = None
  let mut last : @api.Failure? = None
  for label in platform_candidates(desired, fallback) {
    let exchange = client.attempt("/agents", {
      "platform": Json(label),
      "name": Json(name),
      "clientVersion": Json(@config.Version),
      "machineFingerprint": Json(fingerprint),
    })
    if exchange_ok(exchange) {
      let result = exchange.envelope.result
      attempts.push({
        platform: label,
        accepted: true,
        http_status: exchange.http_status,
        status: exchange.envelope.status,
        error: "",
        request_id: exchange.envelope.request_id,
      })
      registered = Some({
        platform: label,
        agent_id: @api.string_field(result, "agentId"),
        agent_token: @api.string_field(result, "agentToken"),
        token_prefix: @api.string_field(result, "tokenPrefix"),
      })
      break
    }
    let failure = @api.failure_of(exchange)
    attempts.push({
      platform: label,
      accepted: false,
      http_status: failure.http_status,
      status: failure.code,
      error: failure.message,
      request_id: failure.request_id,
    })
    last = Some(failure)
    if !label_rejected(failure) {
      raise @api.ApiError(failure)
    }
  }
  guard registered is Some(registered) else {
    let failure = match last {
      Some(failure) => failure
      None => @api.network_failure("no platform label was available to try")
    }
    raise @api.ApiError(failure)
  }
  (attempts, registered)
}
