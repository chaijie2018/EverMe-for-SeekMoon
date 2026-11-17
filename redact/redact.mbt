// The one place secrets are scrubbed. Every string this CLI prints — tool
// results later, error messages now, diagnostics from `doctor` — goes through
// `mask`, because EverMe treats token redaction as a public contract: a full
// `emk_*` / `evt_*` must never reach a terminal, a log, or a model's context.

///|
/// The credential prefixes EverMe mints. Anything else is left alone.
fn secret_prefixes() -> Array[String] {
  ["emk_", "evt_"]
}

///|
/// The number of leading characters redaction keeps: the prefix plus four,
/// e.g. `emk_507d`, enough to correlate an account in support threads without
/// handing anyone a usable key.
const KeptChars : Int32 = 8

///|
/// The shortest token body we treat as a real secret. Upstream mints 32
/// characters; eight keeps the rule from mangling prose like `evt_id`.
const MinBodyChars : Int32 = 8

///|
/// `[a-zA-Z0-9]`, the alphabet EverMe tokens use.
fn is_token_char(ch : Char) -> Bool {
  ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9')
}

///|
/// Replace every full-form `emk_*` / `evt_*` credential with its first eight
/// characters plus `_REDACTED`. Short forms (`emk_507d`) are left untouched,
/// matching upstream.
pub fn mask(text : String) -> String {
  let out = StringBuilder()
  let length = text.length()
  let mut index = 0
  while index < length {
    let mut matched = false
    for prefix in secret_prefixes() {
      if matched {
        continue
      }
      let prefix_length = prefix.length()
      let body_start = index + prefix_length
      if body_start > length {
        continue
      }
      if text[index:body_start].to_owned() != prefix {
        continue
      }
      let mut body_end = body_start
      while body_end < length &&
            is_token_char(text.get_char(body_end).unwrap_or(' ')) {
        body_end = body_end + 1
      }
      if body_end - body_start < MinBodyChars {
        continue
      }
      // Keep `KeptChars` characters of the token itself (prefix included), then
      // mask the rest. A token shorter than that keeps all of it plus the
      // marker, which is still not a usable secret.
      let keep_end = (index + KeptChars).min(body_end)
      out.write_string(text[index:keep_end].to_owned())
      out.write_string("_REDACTED")
      index = body_end
      matched = true
    }
    if !matched {
      out.write_char(text.get_char(index).unwrap_or(' '))
      index = index + 1
    }
  }
  out.to_string()
}

///|
/// The display form of one credential: its kept prefix, never the secret.
pub fn mask_one(secret : String) -> String {
  if secret.is_empty() {
    return ""
  }
  mask(secret)
}
