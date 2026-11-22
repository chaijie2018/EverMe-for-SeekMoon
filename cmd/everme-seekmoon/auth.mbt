// `everme-seekmoon auth …`: get, inspect, adopt, or drop the credential this machine
// uses. The device flow is the default (an `emk_` can be pasted too), and
// `--no-wait`/`--device-code` split it across processes for agents that cannot
// sit in a terminal waiting for a human to click approve.

///|
/// Dispatch `everme-seekmoon auth <subcommand>`.
async fn auth_command(m : @argparse.Matches) -> Int32 {
  guard m.subcommand is Some((name, selected)) else {
    usage(
      "`auth` needs a subcommand: login, status, adopt-evercli, register, logout, or disconnect-agent",
    )
  }
  match name {
    "login" => auth_login(selected)
    "status" => auth_status(selected)
    "adopt-evercli" => auth_adopt(selected)
    "register" => auth_register(selected)
    "logout" => auth_logout(selected)
    "disconnect-agent" => auth_disconnect(selected)
    _ => usage("unknown auth subcommand: \{name}")
  }
}

///|
/// How long to wait between device-flow polls when the backend names no
/// interval.
const DefaultPollSeconds : Int32 = 5

///|
/// How many polls before giving up when the backend reports no expiry.
const MaxPolls : Int32 = 120

///|
/// `everme-seekmoon auth login` — store an API key, resume a device flow, start one and
/// exit, or run the whole flow in this process.
async fn auth_login(m : @argparse.Matches) -> Int32 {
  let paths = @config.Paths::resolve()
  let settings = @config.Settings::resolve()
  let machine = machine_of(m)
  let base = base_of(m, settings)
  let platform = platform_of(m, settings)
  let api_key = value_of(m, "api-key")
  if !api_key.is_empty() {
    return finish_login(paths, base, api_key, "", "", platform, machine)
  }
  let client = @api.Client::new(base~)
  let device_code_flag = value_of(m, "device-code")
  if !device_code_flag.is_empty() {
    return poll_device(paths, client, device_code_flag, platform, machine)
  }
  let fingerprint = @creds.machine_id(paths.machine_file())
  let start = client.device_start(
    platform~,
    client_name="everme-seekmoon",
    client_version=@config.Version,
    fingerprint~,
  )
  if start.device_code.is_empty() || start.verification_url.is_empty() {
    raise @api.ApiError({
      kind: "upstream",
      message: "the backend accepted the request but returned no device flow",
      hint: "check EVERME_API_BASE; a self-hosted gateway may not implement /auth/device",
      http_status: 200,
      code: 0,
      request_id: "",
    })
  }
  if !machine {
    write_stderr(
      "Open \{start.verification_url} and enter the code \{start.user_code}.\n",
    )
    write_stderr(
      "Waiting for approval (the code expires in \{start.expires_in}s)…\n",
    )
  }
  if flag_of(m, "no-wait") {
    save_device_session(paths, start, platform)
    let data : Json = {
      "status": "pending",
      "verificationUrl": Json(start.verification_url),
      "userCode": Json(start.user_code),
      "deviceCode": Json(start.device_code),
      "expiresInSec": Json(start.expires_in),
      "resumeCommand": Json(
        "everme-seekmoon auth login --device-code \{start.device_code}",
      ),
    }
    let text = "open \{start.verification_url} and enter \{start.user_code} (expires in \{start.expires_in}s); then run `everme-seekmoon auth login --device-code \{start.device_code}`"
    emit(machine, text, data)
    return 0
  }
  poll_loop(
    paths,
    client,
    start.device_code,
    start.expires_in,
    start.interval,
    platform,
    machine,
  )
}

///|
/// Persist a `--no-wait` grant so a later process can finish it.
async fn save_device_session(
  paths : @config.Paths,
  start : @api.DeviceStart,
  platform : String,
) -> Unit {
  @fs.mkdir(dirname_of(paths.device_session_file()), recursive=true) catch {
    _ => ()
  }
  let body : Json = {
    "deviceCode": Json(start.device_code),
    "verificationUrl": Json(start.verification_url),
    "userCode": Json(start.user_code),
    "expiresIn": Json(start.expires_in),
    "platform": Json(platform),
  }
  @fs.write_text(paths.device_session_file(), body.stringify()) catch {
    error => fail("cannot write \{paths.device_session_file()}: \{error}")
  }
}

///|
/// The directory part of `path`.
fn dirname_of(path : String) -> String {
  match path.rev_split_once("/") {
    Some((dir, _)) => if dir.is_empty() { "/" } else { dir.to_owned() }
    None => "."
  }
}

///|
/// Poll a device code until it is approved, refused, or out of attempts.
async fn poll_device(
  paths : @config.Paths,
  client : @api.Client,
  device_code : String,
  platform : String,
  machine : Bool,
) -> Int32 {
  poll_loop(paths, client, device_code, 0, DefaultPollSeconds, platform, machine)
}

///|
/// The poll loop itself. `expires_in` of 0 means "the caller gave no budget";
/// `MaxPolls` still bounds it, so a wedged approval never hangs the terminal.
async fn poll_loop(
  paths : @config.Paths,
  client : @api.Client,
  device_code : String,
  expires_in : Int32,
  interval : Int32,
  platform : String,
  machine : Bool,
) -> Int32 {
  let interval = if interval > 0 { interval } else { DefaultPollSeconds }
  let budget = if expires_in > 0 { expires_in / interval + 1 } else { MaxPolls }
  let mut approved : @api.DeviceToken? = None
  let mut polls = 0
  while approved is None && polls < budget {
    let polled = client.device_token(device_code)
    if polled.status == "approved" {
      approved = Some(polled)
      continue
    }
    if polled.status == "expired" {
      not_logged_in(
        "the device code expired before it was approved", "run `everme-seekmoon auth login` again to get a fresh code",
      )
    }
    polls = polls + 1
    if approved is None && polls < budget {
      @async.sleep(interval * 1000)
    }
  }
  guard approved is Some(token) else {
    not_logged_in(
      "the device flow was not approved in time", "run `everme-seekmoon auth login` again",
    )
  }
  write_stderr("approved.\n")
  finish_login(
    paths,
    "",
    token.api_key,
    token.agent_token,
    token.agent_id,
    platform,
    machine,
  )
}

///|
/// Store what the flow produced, cache the account it belongs to, and report.
/// `base` empty means "reuse the configured base".
async fn finish_login(
  paths : @config.Paths,
  base : String,
  api_key : String,
  agent_token : String,
  agent_id : String,
  platform : String,
  machine : Bool,
) -> Int32 {
  let settings = @config.Settings::resolve()
  let base = if base.is_empty() { base_of_empty(settings) } else { base }
  let creds = @creds.Credentials::load(paths.credentials_file())
  apply_login(creds, api_key, agent_token, agent_id)
  if !creds.has_api_key() {
    not_logged_in(
      "the backend approved the flow but returned no API key", "run `everme-seekmoon auth login` again",
    )
  }
  creds.save(paths.credentials_file())
  let info = @api.Client::new(base~).login(creds.api_key)
  let account : @creds.Account = {
    account_id: info.account_id,
    email: info.email,
    api_key_prefix: info.api_key_prefix,
    scopes: info.scopes,
  }
  account.save(paths.account_file()) catch {
    _ => ()
  }
  // Logging in is not finished until this machine has an identity of its own:
  // without an agent token the memory endpoints cannot attribute a single row.
  // A refused registration does not undo the login — the credential is stored
  // and `auth register --platform <label>` can try another label later.
  let mut mine = creds.agent_id
  // An agent that arrived with the flow was minted by this login, so it is news
  // even though nothing was registered locally afterwards.
  let mut registered = !agent_token.is_empty()
  let mut agent_error = ""
  if !creds.has_agent_token() {
    let outcome : Result[(String, Bool), @api.Failure] = Ok(
      ensure_agent(paths, base, platform),
    ) catch {
      @api.ApiError(failure) => Err(failure)
      error => raise error
    }
    match outcome {
      Ok((id, now)) => {
        mine = id
        registered = now
      }
      Err(failure) => {
        agent_error = if failure.hint.is_empty() {
          failure.message
        } else {
          "\{failure.message} (\{failure.hint})"
        }
      }
    }
  }
  let data : Json = {
    "loggedIn": true,
    "email": Json(info.email),
    "accountId": Json(info.account_id),
    "apiKey": Json(@redact.mask(creds.api_key)),
    "agentToken": Json(@redact.mask(creds.agent_token)),
    "agentId": Json(mine),
    "agentRegistered": Json(registered),
    "agentError": Json(agent_error),
    "scopes": Json(info.scopes),
    "credentialsFile": Json(paths.credentials_file()),
  }
  let text = "logged in as \{info.email} (\{@redact.mask(creds.api_key)})\n" +
    "  credentials \{paths.credentials_file()}\n" +
    "  \{agent_state_text(mine, registered, agent_error)}"
  emit(machine, text, data)
  0
}

///|
/// Fold a login result into the stored credential.
///
/// A different account drops the agent this CLI had: an `evt_` belongs to the
/// account that minted it, so carrying one over would file this machine's
/// memories under the previous account's agent — and the platform label would
/// be the old account's too.
fn apply_login(
  creds : @creds.Credentials,
  api_key : String,
  agent_token : String,
  agent_id : String,
) -> Unit {
  let different_account = !api_key.is_empty() &&
    !creds.api_key.is_empty() &&
    creds.api_key != api_key
  if different_account {
    forget_agent(creds)
  }
  if !api_key.is_empty() {
    creds.api_key = api_key
  }
  if !agent_token.is_empty() {
    creds.agent_token = agent_token
  }
  if !agent_id.is_empty() {
    creds.agent_id = agent_id
  }
}

///|
/// The API root from settings alone (no command-line overrides in scope).
fn base_of_empty(settings : @config.Settings) -> String raise {
  @config.api_root(settings.api_base)
}

///|
/// `everme-seekmoon auth status` — what is stored, masked, plus the cached account.
async fn auth_status(m : @argparse.Matches) -> Int32 {
  let paths = @config.Paths::resolve()
  let machine = machine_of(m)
  let creds = @creds.Credentials::load(paths.credentials_file())
  let account = @creds.Account::load(paths.account_file())
  let account_json : Json = match account {
    Some(account) =>
      {
        "accountId": Json(account.account_id),
        "email": Json(account.email),
        "apiKeyPrefix": Json(account.api_key_prefix),
        "scopes": Json(account.scopes),
      }
    None => Json::null()
  }
  let data : Json = {
    "loggedIn": Json(creds.has_api_key()),
    "apiKey": Json(@redact.mask(creds.api_key)),
    "agentToken": Json(@redact.mask(creds.agent_token)),
    "agentId": Json(creds.agent_id),
    "platform": Json(creds.platform),
    "tokenPrefix": Json(creds.token_prefix),
    "credentialsFile": Json(paths.credentials_file()),
    "account": account_json,
  }
  let who = match account {
    Some(account) =>
      if account.email.is_empty() {
        "unknown account"
      } else {
        account.email
      }
    None => "no cached account"
  }
  let text = if creds.has_api_key() {
    "logged in: \{who}\n  api-key     \{@redact.mask(creds.api_key)}\n  agent-token \{@redact.mask(creds.agent_token)}\n  agent-id    \{if creds.agent_id.is_empty() { "none" } else { creds.agent_id }}\n  platform    \{if creds.platform.is_empty() { "none" } else { creds.platform }}\n  stored at   \{paths.credentials_file()}"
  } else {
    "not logged in (run `everme-seekmoon auth login`, or `everme-seekmoon auth adopt-evercli` to reuse an evercli login)"
  }
  emit(machine, text, data)
  0
}

///|
/// `everme-seekmoon auth adopt-evercli` — take the credential the upstream CLI already
/// stored on this machine, then verify it and cache the account.
async fn auth_adopt(m : @argparse.Matches) -> Int32 {
  let paths = @config.Paths::resolve()
  let settings = @config.Settings::resolve()
  let machine = machine_of(m)
  let base = base_of(m, settings)
  let platform = platform_of(m, settings)
  let home = @config.home()
  let adopted = @creds.adopt_evercli(home)
  guard adopted is Some(adopted) else {
    not_logged_in(
      "no evercli login found at \{home}/.local/share/evercli/credentials.json",
      "run `evercli auth login` first, or `everme-seekmoon auth login`",
    )
  }
  let creds = @creds.Credentials::load(paths.credentials_file())
  // Only the account key crosses over. The agent token in that file belongs to
  // whichever agent evercli registered; borrowing it would make this CLI's
  // memories show up as that agent's, and it would break the day evercli
  // rotates it. `finish_login` registers our own agent on the way out.
  creds.api_key = adopted.api_key
  creds.save(paths.credentials_file())
  finish_login(paths, base, creds.api_key, "", "", platform, machine)
}

///|
/// `everme-seekmoon auth register` — bind this machine to the account as an agent.
/// Idempotent: with an agent token already stored it reports that one and
/// registers nothing. This is the repair path after `auth disconnect-agent`, a
/// dropped token, or a rejected platform label.
async fn auth_register(m : @argparse.Matches) -> Int32 {
  let paths = @config.Paths::resolve()
  let settings = @config.Settings::resolve()
  let machine = machine_of(m)
  let base = base_of(m, settings)
  let platform = platform_of(m, settings)
  let (agent_id, registered) = ensure_agent(paths, base, platform)
  let creds = @creds.Credentials::load(paths.credentials_file())
  let text = "\{agent_state_text(agent_id, registered, "")}\n  platform  \{if creds.platform.is_empty() { "unrecorded" } else { creds.platform }}\n  stored at \{paths.credentials_file()}"
  emit(machine, text, {
    "agentId": Json(agent_id),
    "registered": Json(registered),
    "platform": Json(creds.platform),
    "credentialsFile": Json(paths.credentials_file()),
  })
  0
}

///|
/// `everme-seekmoon auth logout` — remove the stored credential and the account cache.
async fn auth_logout(m : @argparse.Matches) -> Int32 {
  let paths = @config.Paths::resolve()
  let machine = machine_of(m)
  @fs.remove(paths.credentials_file(), allow_missing=true)
  @fs.remove(paths.account_file(), allow_missing=true)
  @fs.remove(paths.device_session_file(), allow_missing=true)
  emit(
    machine,
    "logged out; the credential was removed from \{paths.credentials_file()}",
    { "loggedIn": false, "credentialsFile": Json(paths.credentials_file()) },
  )
  0
}

///|
/// `everme-seekmoon auth disconnect-agent --agent-id <id>` — retire an agent on this
/// account, e.g. one this CLI registered under a label it no longer wants. When
/// it is our own agent, the stored token goes with it: a token for a
/// disconnected agent is exactly the stale identity this CLI refuses to keep.
async fn auth_disconnect(m : @argparse.Matches) -> Int32 {
  let paths = @config.Paths::resolve()
  let settings = @config.Settings::resolve()
  let machine = machine_of(m)
  let base = base_of(m, settings)
  let creds = @creds.Credentials::load(paths.credentials_file())
  if !creds.has_api_key() {
    not_logged_in(
      "no API key stored, so this agent cannot be disconnected", "run `everme-seekmoon auth login` first",
    )
  }
  let agent_id = value_of(m, "agent-id")
  if agent_id.is_empty() {
    usage(
      "pass --agent-id <id>; `everme-seekmoon doctor` prints this CLI's own agent id",
    )
  }
  let client = @api.Client::new(base~).with_token(creds.api_key)
  client.disconnect_agent(agent_id)
  let mine = creds.agent_id == agent_id
  if mine {
    creds.agent_id = ""
    creds.agent_token = ""
    creds.platform = ""
    creds.token_prefix = ""
    creds.save(paths.credentials_file()) catch {
      _ => ()
    }
  }
  let text = if mine {
    "disconnected agent \{agent_id} and forgot its token; run `everme-seekmoon auth register` to bind this machine again"
  } else {
    "disconnected agent \{agent_id}; this CLI's own credential is unchanged"
  }
  emit(machine, text, {
    "agentId": Json(agent_id),
    "disconnected": true,
    "wasThisCli": Json(mine),
  })
  0
}
