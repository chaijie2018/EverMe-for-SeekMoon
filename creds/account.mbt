// Two small caches beside the credential store: the account snapshot
// `auth status` prints, and the machine id the agent fingerprint is derived
// from. Neither is secret; both live under the config/data directories.

///|
/// The account an `emk_` belongs to, as `POST /auth/login` reported it.
pub(all) struct Account {
  account_id : String
  email : String
  api_key_prefix : String
  scopes : Array[String]
}

///|
/// One hex digit for `value` in `0..<16`.
fn hex_digit(value : Int32) -> Char {
  let digits = "0123456789abcdef"
  digits.get_char(value).unwrap_or('0')
}

///|
/// Lowercase hex for a byte sequence.
pub fn to_hex(bytes : Bytes) -> String {
  let out = StringBuilder()
  for byte in bytes {
    let value = byte.to_int()
    out.write_char(hex_digit((value >> 4) & 0xF))
    out.write_char(hex_digit(value & 0xF))
  }
  out.to_string()
}

///|
/// Persist the account snapshot; failure to write it is not fatal, because the
/// credential is what actually authenticates.
pub async fn Account::save(self : Account, path : String) -> Unit {
  @fs.mkdir(dirname(path), recursive=true, permission=ModePrivateDir) catch {
    _ => ()
  }
  let body : Json = {
    "accountId": Json(self.account_id),
    "email": Json(self.email),
    "apiKeyPrefix": Json(self.api_key_prefix),
    "scopes": Json(self.scopes),
  }
  @fs.write_text(path, body.stringify(), permission=ModePrivateFile)
}

///|
/// The cached account, or `None` when it was never written.
pub async fn Account::load(path : String) -> Account? {
  let text = @fs.read_text(path) catch { _ => return None }
  let json = @json.parse(text) catch { _ => return None }
  let scopes : Array[String] = match json {
    Object(fields) =>
      match fields.get("scopes") {
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
  Some({
    account_id: string_field(json, "accountId"),
    email: string_field(json, "email"),
    api_key_prefix: string_field(json, "apiKeyPrefix"),
    scopes,
  })
}

///|
/// The stable machine id: generated once and then reused, so the agent
/// fingerprint (and therefore the registered agent) survives restarts. A
/// machine whose entropy source refuses still gets an id — weaker, but
/// reusable, which is what matters here.
pub async fn machine_id(path : String) -> String {
  let existing_text = @fs.read_text(path) catch { _ => "" }
  if !existing_text.is_empty() {
    let json = @json.parse(existing_text) catch { _ => Json::null() }
    let existing = string_field(json, "id")
    if !existing.is_empty() {
      return existing
    }
  }
  let fresh = match @env.rand(16) {
    Some(bytes) => to_hex(bytes)
    None => "fallback-\{@env.now()}"
  }
  let body : Json = { "id": Json(fresh) }
  @fs.mkdir(dirname(path), recursive=true, permission=ModePrivateDir) catch {
    _ => ()
  }
  @fs.write_text(path, body.stringify(), permission=ModePrivateFile) catch {
    _ => ()
  }
  fresh
}
