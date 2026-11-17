// The credential store: one 0600 JSON file holding the `emk_` API key and the
// `evt_` agent token, written atomically (temp file + rename) under a 0700
// directory. The file mode is the boundary that keeps another local user out;
// the CLI never puts a secret anywhere else — not in MCP config, not in logs.

///|
/// File mode `0600`: owner read/write only.
const ModePrivateFile : Int32 = 384

///|
/// Directory mode `0700`: owner only.
const ModePrivateDir : Int32 = 448

///|
/// What we know about this installation's EverMe identity. Empty strings mean
/// "absent", which keeps `!= ""` reads simple at the call sites.
///
/// Two levels are kept apart on purpose: `api_key` is the account (`emk_`),
/// which may be reused from another client, while `agent_token` is *this*
/// agent's identity (`evt_`). A token is only ever stored here after this CLI
/// registered the agent it belongs to — see `adopt_evercli`.
pub(all) struct Credentials {
  mut api_key : String
  mut agent_token : String
  mut agent_id : String
  /// The platform label this agent was registered under, so a mismatch can be
  /// detected instead of silently reading and writing as somebody else.
  mut platform : String
  /// The `tokenPrefix` the backend assigned at registration; the agent list
  /// repeats it, which is what makes the stored token verifiable.
  mut token_prefix : String
}

///|
/// Nothing stored yet.
pub fn Credentials::empty() -> Credentials {
  {
    api_key: "",
    agent_token: "",
    agent_id: "",
    platform: "",
    token_prefix: "",
  }
}

///|
/// Whether an account-level key is available.
pub fn Credentials::has_api_key(self : Credentials) -> Bool {
  !self.api_key.is_empty()
}

///|
/// Whether an agent token is available (the memory endpoints need this one).
pub fn Credentials::has_agent_token(self : Credentials) -> Bool {
  !self.agent_token.is_empty()
}

///|
/// The directory part of `path`, or `.` when it has none.
pub fn dirname(path : String) -> String {
  match path.rev_split_once("/") {
    Some((dir, _)) => if dir.is_empty() { "/" } else { dir.to_owned() }
    None => "."
  }
}

///|
/// Read `field` of `json` as a string, or "" when absent or not a string.
fn string_field(json : Json, field : String) -> String {
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
/// Load the store, tolerating an absent or unreadable file: a first run has
/// none, and a corrupted one must not stop `auth login` from repairing it.
pub async fn Credentials::load(path : String) -> Credentials {
  let text = @fs.read_text(path) catch { _ => return Credentials::empty() }
  let json = @json.parse(text) catch { _ => return Credentials::empty() }
  {
    api_key: string_field(json, "apiKey"),
    agent_token: string_field(json, "agentToken"),
    agent_id: string_field(json, "agentId"),
    platform: string_field(json, "platform"),
    token_prefix: string_field(json, "tokenPrefix"),
  }
}

///|
/// Write the store atomically with mode `0600`.
pub async fn Credentials::save(self : Credentials, path : String) -> Unit {
  let dir = dirname(path)
  @fs.mkdir(dir, recursive=true, permission=ModePrivateDir) catch {
    _ => ()
  }
  ignore(@fs.chmod(dir, ModePrivateDir) catch { _ => () })
  let body : Json = {
    "apiKey": Json(self.api_key),
    "agentToken": Json(self.agent_token),
    "agentId": Json(self.agent_id),
    "platform": Json(self.platform),
    "tokenPrefix": Json(self.token_prefix),
  }
  let temp = path + ".tmp"
  @fs.write_text(temp, body.stringify(), permission=ModePrivateFile)
  @fs.rename(temp, path, replace=true)
  ignore(@fs.chmod(path, ModePrivateFile) catch { _ => () })
}

///|
/// What `auth status` prints: prefixes only, never a usable secret.
pub fn Credentials::summary(self : Credentials) -> String {
  let api = if self.api_key.is_empty() {
    "none"
  } else {
    @redact.mask(self.api_key)
  }
  let agent = if self.agent_token.is_empty() {
    "none"
  } else {
    @redact.mask(self.agent_token)
  }
  let id = if self.agent_id.is_empty() { "none" } else { self.agent_id }
  let platform = if self.platform.is_empty() { "none" } else { self.platform }
  "api-key=\{api}  agent-token=\{agent}  agent-id=\{id}  platform=\{platform}"
}

///|
/// Adopt the *account* login the upstream `evercli` already made on this
/// machine, so a user who ran `evercli auth login` earlier does not have to log
/// in twice.
///
/// Only the `emk_` key comes across. The `agent-token` in that file belongs to
/// whichever agent evercli registered — a `workbuddy` or `evercli` slot, say —
/// and adopting it would attribute this CLI's memories to that agent and break
/// the moment the other client rotates it. Identity is not reusable; the agent
/// token must come from our own `POST /agents`.
pub async fn adopt_evercli(home : String) -> Credentials? {
  let path = home + "/.local/share/evercli/credentials.json"
  let text = @fs.read_text(path) catch { _ => return None }
  let json = @json.parse(text) catch { _ => return None }
  let api_key = string_field(json, "api-key")
  if api_key.is_empty() {
    return None
  }
  let adopted = Credentials::empty()
  adopted.api_key = api_key
  Some(adopted)
}

///|
/// Whether `token_prefix` still describes `agent_id` in this account's agent
/// list. Used before the credential is trusted: a token whose owner we cannot
/// name is a token we do not use.
pub fn verify_agent(
  agent_id : String,
  token_prefix : String,
  platform : String,
  items : Array[Json],
) -> Result[Unit, String] {
  guard !agent_id.is_empty() else {
    return Err(
      "no agent id is stored, so the stored token cannot be attributed",
    )
  }
  let mut found : Json? = None
  for item in items {
    if string_field(item, "id") == agent_id {
      found = Some(item)
    }
  }
  guard found is Some(item) else {
    return Err(
      "agent \{agent_id} is not in this account's agent list (disconnected or belonging to another account)",
    )
  }
  let listed_prefix = string_field(item, "tokenPrefix")
  if !token_prefix.is_empty() &&
    !listed_prefix.is_empty() &&
    listed_prefix != token_prefix {
    return Err(
      "the stored token (prefix \{token_prefix}) is not the one agent \{agent_id} holds (prefix \{listed_prefix})",
    )
  }
  let listed_platform = string_field(item, "platform")
  if !platform.is_empty() &&
    !listed_platform.is_empty() &&
    listed_platform != platform {
    return Err(
      "agent \{agent_id} belongs to platform \{listed_platform}, not \{platform}",
    )
  }
  Ok(())
}
