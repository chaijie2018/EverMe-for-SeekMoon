// What the CLI writes and the status it exits with. Two shapes, one for a
// person and one for a script, exactly the EverMe public contract: results on
// stdout, diagnostics on stderr, an `ok`/`error` envelope under `--format
// json`, and the same coarse exit codes `evercli` uses.

///|
/// Whether `--format` asks for the machine envelope. `auto` resolves to the
/// human form here: this CLI is run by a person or by a script that passed
/// `json` explicitly, and guessing from a terminal probe would make the two
/// indistinguishable in tests.
pub fn machine_format(name : String) -> Bool raise {
  match name {
    "text" | "auto" => false
    "json" => true
    _ => fail("invalid value for --format: \{name} (use text or json)")
  }
}

///|
/// The success envelope: `{"ok":true,"data":…}`.
pub fn ok_envelope(data : Json) -> Json {
  { "ok": true, "data": data }
}

///|
/// The failure envelope: `{"ok":false,"error":{"type","code","message","hint","detail"}}`.
pub fn error_envelope(failure : @api.Failure) -> Json {
  {
    "ok": false,
    "error": {
      "type": Json(failure.kind),
      "code": Json(failure.code),
      "message": Json(failure.message),
      "hint": Json(failure.hint),
      "detail": {
        "httpStatus": Json(failure.http_status),
        "requestId": Json(failure.request_id),
      },
    },
  }
}

///|
/// The terminal form of a failure: a message and, when there is one, the next
/// action — never a bare exception dump.
pub fn render_failure(failure : @api.Failure) -> String {
  let hint = if failure.hint.is_empty() {
    ""
  } else {
    "\nhint: \{failure.hint}"
  }
  "error: \{failure.message}\{hint}"
}

///|
/// The process status for a failure kind. Coarse on purpose: callers should
/// branch on `error.type`, and these codes only separate the broad classes
/// (the same mapping upstream documents).
pub fn exit_code(kind : String) -> Int32 {
  match kind {
    "invalid_args" => 2
    "not_logged_in" | "auth" => 3
    "network" => 4
    "io" => 5
    "cancelled" => 130
    _ => 1
  }
}

///|
/// Whether a failure kind is a local/credential problem rather than a backend
/// answer — used to keep `doctor` from claiming the backend rejected anything
/// when it was never reached.
pub fn is_local(kind : String) -> Bool {
  match kind {
    "not_logged_in" | "io" | "invalid_args" | "network" => true
    _ => false
  }
}
