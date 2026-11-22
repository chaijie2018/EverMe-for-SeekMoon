// What a run talks to: the EverMe API root and the platform label this CLI
// registers under. Both are environment-overridable, because a self-hosted
// EverOS endpoint and a backend that rejects `seekmoon` (see design §12.1)
// must not require a rebuild.

///|
/// The managed EverMe gateway.
pub const DefaultApiBase : String = "https://api.everme.evermind.ai"

///|
/// The platform label this CLI registers under. `evercli` is what upstream's
/// own CLI uses in `auth login`, so it reads as "some command-line client"
/// rather than impersonating another product, and the managed backend accepts
/// it. `seekmoon` was verified to be rejected (`status=20004`,
/// "does not validate as known_platform"); when upstream adds it, either change
/// this constant or pass `--platform seekmoon`.
pub const DefaultPlatform : String = "evercli"

///|
/// The version this build reports to EverMe and in its own `--version`.
pub const Version : String = "0.1.1"

///|
/// Which endpoint and which platform label to use.
pub(all) struct Settings {
  api_base : String
  platform : String
}

///|
/// Read `name`, trimmed, or `fallback` when unset or blank.
pub fn env_or(name : String, fallback : String) -> String {
  match @env.get_env_var(name) {
    Some(value) =>
      if value.trim().is_empty() {
        fallback
      } else {
        value.trim().to_owned()
      }
    None => fallback
  }
}

///|
/// Resolve from the environment with the managed defaults.
pub fn Settings::resolve() -> Settings {
  {
    api_base: env_or("EVERME_API_BASE", DefaultApiBase),
    platform: env_or("EVERME_PLATFORM", DefaultPlatform),
  }
}

///|
/// Strip trailing slashes, then append `/api/v1` unless the value already
/// ends in a `/api/v<N>` segment — the same idempotent normalization the
/// upstream CLI applies, so `https://host` and `https://host/api/v1` agree.
pub fn api_root(api_base : String) -> String raise {
  if !(api_base.has_prefix("https://") || api_base.has_prefix("http://")) {
    fail(
      "invalid API base \{api_base}: expected an http(s) URL (set EVERME_API_BASE)",
    )
  }
  let mut base = api_base.trim().to_owned()
  while base.has_suffix("/") {
    base = base[:base.length() - 1].to_owned()
  }
  let marker = base.find("/api/v")
  match marker {
    Some(index) => {
      let tail : StringView = base[index + 6:]
      // Accept only `/api/v<digits>` with nothing after it.
      if !tail.is_empty() && tail.all(ch => ch is ('0'..<='9')) {
        return base
      }
      base + "/api/v1"
    }
    None => base + "/api/v1"
  }
}
