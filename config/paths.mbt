// Where this CLI keeps its files, resolved the way `evercli` does: XDG
// variables when they name an absolute path, platform-canonical fallbacks
// otherwise. Three buckets, same split as upstream:
//
//   - config: settings and the cached account (nothing secret)
//   - data:   credentials, the device-flow session, the machine id
//   - cache:  scratch (nothing written yet; kept so the layout matches)

///|
/// The resolved directory layout.
pub(all) struct Paths {
  config_dir : String
  data_dir : String
  cache_dir : String
}

///|
/// `$XDG_<bucket>_HOME/<app>` when the variable is absolute, else
/// `<fallback>/<app>`. The XDG spec says implementations MUST ignore relative
/// values; honoring that closes the `XDG_CONFIG_HOME=:evil` footgun that would
/// otherwise drop credentials beside the current directory.
fn bucket(env_name : String, fallback : String, app : String) -> String {
  let base = match @env.get_env_var(env_name) {
    Some(value) => if value.has_prefix("/") { value } else { fallback }
    None => fallback
  }
  base + "/" + app
}

///|
/// The user's home directory, or a failure naming both variables we accept.
pub fn home() -> String raise {
  match @env.get_env_var("HOME") {
    Some(home) => if !home.is_empty() { return home }
    None => ()
  }
  match @env.get_env_var("USERPROFILE") {
    Some(home) => if !home.is_empty() { return home }
    None => ()
  }
  fail("cannot locate the home directory: set HOME (or USERPROFILE on Windows)")
}

///|
/// Resolve the three directories under `home`.
pub fn Paths::resolve() -> Paths raise {
  let home = home()
  {
    config_dir: bucket("XDG_CONFIG_HOME", home + "/.config", "everme-seekmoon"),
    data_dir: bucket("XDG_DATA_HOME", home + "/.local/share", "everme-seekmoon"),
    cache_dir: bucket("XDG_CACHE_HOME", home + "/.cache", "everme-seekmoon"),
  }
}

///|
/// The credential file (`0600`): `emk_` API key and `evt_` agent token.
pub fn Paths::credentials_file(self : Paths) -> String {
  self.data_dir + "/credentials.json"
}

///|
/// The cached account (`account.json`): account id, email, scopes. No secrets.
pub fn Paths::account_file(self : Paths) -> String {
  self.config_dir + "/account.json"
}

///|
/// A `--no-wait` device-flow session, so a later `--device-code` can resume it.
pub fn Paths::device_session_file(self : Paths) -> String {
  self.data_dir + "/device-session.json"
}

///|
/// The stable machine id the agent fingerprint is derived from.
pub fn Paths::machine_file(self : Paths) -> String {
  self.data_dir + "/machine.json"
}
