// Registering this machine's agent is the one call the backend can refuse by
// *value*: it validates `platform` against its own `known_platform` enum, and
// `seekmoon` is not in it (HTTP 400, `status=20004`, "platform: seekmoon does
// not validate as known_platform").
//
// So the default label is the one that is known to work — `evercli`, which is
// what upstream's own CLI registers, and which reads as "some command-line
// client" rather than impersonating a specific product. There is no negotiation
// step: the label is a default you can override with `--platform` (for a
// self-hosted EverOS, or once upstream whitelists `seekmoon`), not something
// this CLI guesses its way through.
//
// What is never negotiable is the identity: this is our own `POST /agents`,
// minting our own agent and our own token. Borrowing another agent's token would
// file this CLI's memories under that agent (design §12.2), which is why
// `adopt-evercli` takes only the account key.

///|
/// One registration call, kept so the report can show the label that was tried
/// and exactly what the backend answered.
pub(all) struct Attempt {
  platform : String
  http_status : Int32
  status : Int32
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
/// The hint attached to a rejected label: the backend told us the value is not
/// known, so the next action is to drop the override rather than retry.
fn label_hint() -> String {
  "the managed backend accepts `evercli` (the default); set a label from its known_platform, or unset --platform"
}

///|
/// Register this machine's agent under `platform`, exactly once. Returns the
/// call that succeeded; a rejection of the label itself is reported with the
/// backend's own words plus what to do about it, not retried under another one.
pub async fn register_agent(
  client : @api.Client,
  fingerprint : String,
  platform : String,
  name : String,
) -> (Attempt, Registered) {
  let exchange = client.attempt("/agents", {
    "platform": Json(platform),
    "name": Json(name),
    "clientVersion": Json(@config.Version),
    "machineFingerprint": Json(fingerprint),
  })
  let attempt : Attempt = {
    platform,
    http_status: exchange.http_status,
    status: exchange.envelope.status,
    request_id: exchange.envelope.request_id,
  }
  if !exchange_ok(exchange) {
    let failure = @api.failure_of(exchange)
    // A value rejection is the only one worth a tailored hint: everything else
    // keeps the taxonomy's own advice.
    let hint = if failure.kind == "invalid_args" {
      label_hint()
    } else {
      failure.hint
    }
    raise @api.ApiError({
      kind: failure.kind,
      message: failure.message,
      hint,
      http_status: failure.http_status,
      code: failure.code,
      request_id: failure.request_id,
    })
  }
  let result = exchange.envelope.result
  (
    attempt,
    {
      platform,
      agent_id: @api.string_field(result, "agentId"),
      agent_token: @api.string_field(result, "agentToken"),
      token_prefix: @api.string_field(result, "tokenPrefix"),
    },
  )
}

///|
/// Drop this CLI's agent identity in memory: the token, the id, and the label
/// they were registered under. Used when the agent is known to belong to another
/// account, so the next registration cannot inherit it.
fn forget_agent(creds : @creds.Credentials) -> Unit {
  creds.agent_id = ""
  creds.agent_token = ""
  creds.platform = ""
  creds.token_prefix = ""
}

///|
/// The agent this machine already has, or a freshly registered one. Returns
/// `(agentId, registeredNow)`. Idempotent on purpose: an agent the account still
/// lists as connected is reused, so running this twice does not pile up agents.
pub async fn ensure_agent(
  paths : @config.Paths,
  base : String,
  platform : String,
) -> (String, Bool) raise {
  let creds = @creds.Credentials::load(paths.credentials_file())
  if !creds.has_api_key() {
    not_logged_in(
      "no API key stored, so no agent can be registered", "run `everme-seekmoon auth login`, or `everme-seekmoon auth adopt-evercli` to reuse an evercli login",
    )
  }
  let client = @api.Client::new(base~).with_token(creds.api_key)
  let fingerprint = @creds.machine_id(paths.machine_file())
  if creds.has_agent_token() &&
    agent_still_listed(client, creds, platform, fingerprint~) {
    return (creds.agent_id, false)
  }
  // Either this machine has no identity, or the account no longer lists the one
  // it has. A dead token must not survive into the registration below, and the
  // label it carried says nothing about the label to try next.
  forget_agent(creds)
  let (_, agent) = register_agent(client, fingerprint, platform, "SeekMoon")
  creds.agent_id = agent.agent_id
  creds.agent_token = agent.agent_token
  creds.platform = agent.platform
  creds.token_prefix = agent.token_prefix
  creds.save(paths.credentials_file())
  (agent.agent_id, true)
}

///|
/// Whether the account still lists our agent as connected. A stored token is not
/// proof of life: an agent can be retired from another machine, and evercli
/// rotates the one it adopted, so `auth register` asks instead of assuming.
///
/// The lookup uses the label the agent was registered under, not the one being
/// registered now — otherwise a stale label would look like a missing agent and
/// every attempt would mint a new one. The rule for "still ours" is
/// `Credentials::verify_agent`, the same one `doctor` reports by.
async fn agent_still_listed(
  client : @api.Client,
  creds : @creds.Credentials,
  platform : String,
  fingerprint~ : String,
) -> Bool raise {
  if creds.agent_id.is_empty() {
    return false
  }
  let label = if creds.platform.is_empty() { platform } else { creds.platform }
  let items = client.list_agents(platform=label, fingerprint~)
  @creds.verify_agent(
    creds.agent_id,
    effective_prefix(creds),
    creds.platform,
    items,
  ) is Ok(_)
}

///|
/// One line saying what the credential store holds as an identity, for a login
/// that registered on the way (or failed to).
fn agent_state_text(agent_id : String, registered : Bool, error : String) -> String {
  if !error.is_empty() {
    "agent none  (registration failed: \{error})"
  } else if agent_id.is_empty() {
    "agent none"
  } else if registered {
    "agent \{agent_id}  (registered now)"
  } else {
    "agent \{agent_id}  (already stored)"
  }
}
