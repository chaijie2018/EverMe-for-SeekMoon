// Small helpers shared by the command implementations: reading argparse
// results, resolving the effective API base and platform, and writing output
// in whichever shape `--format` asked for.

///|
/// The first value of option `name`, or "" when it was not supplied.
fn value_of(m : @argparse.Matches, name : String) -> String {
  match m.values.get(name) {
    Some(values) =>
      match values {
        [value, ..] => value
        _ => ""
      }
    None => ""
  }
}

///|
/// Whether flag `name` was set.
fn flag_of(m : @argparse.Matches, name : String) -> Bool {
  match m.flags.get(name) {
    Some(value) => value
    None => false
  }
}

///|
/// Whether this invocation asked for the machine envelope.
fn machine_of(m : @argparse.Matches) -> Bool raise {
  @cli.machine_format(value_of(m, "format"))
}

///|
/// The platform label to register under: the flag, else `EVERME_PLATFORM`,
/// else `seekmoon`.
fn platform_of(m : @argparse.Matches, settings : @config.Settings) -> String {
  let flag = value_of(m, "platform")
  if flag.is_empty() {
    settings.platform
  } else {
    flag
  }
}

///|
/// The effective API root: the flag, else `EVERME_API_BASE`, else the managed
/// gateway — normalized to `…/api/v1`.
fn base_of(m : @argparse.Matches, settings : @config.Settings) -> String raise {
  let flag = value_of(m, "api-base")
  let base = if flag.is_empty() { settings.api_base } else { flag }
  @config.api_root(base)
}

///|
/// Write one result: the human lines, or the `{"ok":true,"data":…}` envelope.
fn emit(machine : Bool, text : String, data : Json) -> Unit {
  if machine {
    println(@cli.ok_envelope(data).stringify())
  } else {
    println(text)
  }
}

///|
/// Write to stderr without letting a broken pipe escape.
async fn write_stderr(text : String) -> Unit {
  @stdio.stderr.text.write(text) catch {
    _ => ()
  }
}

///|
/// A usage error: the caller's arguments, not its luck. Generic so a raising
/// arm can stand wherever any type is expected.
fn[T] usage(message : String) -> T raise {
  raise @api.ApiError({
    kind: "invalid_args",
    message,
    hint: "run `everme --help` for usage",
    http_status: 0,
    code: 0,
    request_id: "",
  })
}

///|
/// A missing-credential error, classified so the exit status says what to fix.
fn[T] not_logged_in(message : String, hint : String) -> T raise {
  raise @api.ApiError({
    kind: "not_logged_in",
    message,
    hint,
    http_status: 0,
    code: 0,
    request_id: "",
  })
}
