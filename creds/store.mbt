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
pub(all) struct Credentials {
  mut api_key : String
  mut agent_token : String
  mut agent_id : String
}

///|
/// Nothing stored yet.
pub fn Credentials::empty() -> Credentials {
  { api_key: "", agent_token: "", agent_id: "", }
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
  "api-key=\{api}  agent-token=\{agent}  agent-id=\{id}"
}

///|
/// Adopt a login the upstream `evercli` already made on this machine, so a
/// user who ran `evercli auth login` earlier does not have to log in twice.
/// Its `credentials.json` is a flat `{"<key>": "<secret>"}` map; a missing or
/// malformed file means "nothing to adopt". Reads only — never writes there.
pub async fn adopt_evercli(home : String) -> Credentials? {
  let path = home + "/.local/share/evercli/credentials.json"
  let text = @fs.read_text(path) catch { _ => return None }
  let json = @json.parse(text) catch { _ => return None }
  let api_key = string_field(json, "api-key")
  let agent_token = string_field(json, "agent-token")
  if api_key.is_empty() && agent_token.is_empty() {
    return None
  }
  Some({ api_key, agent_token, agent_id: "", })
}
