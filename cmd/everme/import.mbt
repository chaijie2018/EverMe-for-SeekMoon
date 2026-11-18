// `everme import sessions` — cold start: put this machine's existing SeekMoon
// conversations into EverMe, so "what did we do last time?" has an answer on day
// one. It is idempotent: a cursor per session means a second run sends only what
// was appended since.

///|
/// Where sessions live, preferring the workspace store this CLI was run in and
/// falling back to the user-level one.
async fn default_store() -> String {
  let cwd = @env.current_dir().unwrap_or(".")
  let workspace_store = cwd + "/.openseek/sessions"
  let exists = @fs.exists(workspace_store) catch { _ => false }
  if exists {
    workspace_store
  } else {
    @config.home() + "/.openseek/sessions"
  }
}

///|
/// `everme import <subcommand>`.
async fn import_command(m : @argparse.Matches) -> Int32 {
  guard m.subcommand is Some((name, selected)) else {
    usage("`import` needs a subcommand: sessions")
  }
  match name {
    "sessions" => import_sessions(selected)
    _ => usage("unknown import subcommand: \{name}")
  }
}

///|
/// Parse a non-negative integer option, defaulting to 0.
fn number_of(m : @argparse.Matches, name : String) -> Int32 raise {
  let text = value_of(m, name)
  if text.trim().is_empty() {
    return 0
  }
  let value : Int32 = @string.from_str(text.trim()) catch {
    _ =>
      raise @api.ApiError({
        kind: "invalid_args",
        message: "--\{name} expects a number, got: \{text}",
        hint: "",
        http_status: 0,
        code: 0,
        request_id: "",
      })
  }
  if value < 0 {
    raise @api.ApiError({
      kind: "invalid_args",
      message: "--\{name} must not be negative",
      hint: "",
      http_status: 0,
      code: 0,
      request_id: "",
    })
  }
  value
}

///|
/// `everme import sessions`.
async fn import_sessions(selected : @argparse.Matches) -> Int32 {
  let machine = machine_of(selected)
  let paths = @config.Paths::resolve()
  let settings = @config.Settings::resolve()
  let base = base_of(selected, settings)
  let store = match value_of(selected, "store") {
    "" => default_store()
    store => store
  }
  let dry_run = flag_of(selected, "dry-run")
  let options : @importer.ImportOptions = {
    store,
    state_file: paths.data_dir + "/import-state.json",
    since_days: number_of(selected, "since-days"),
    limit: number_of(selected, "limit"),
    batch_size: match number_of(selected, "batch") {
      0 => 100
      size => size
    },
    dry_run,
  }
  // A dry run never touches the backend, so it must not demand a credential
  // either: it answers "what would this send?" even with only an emk stored.
  let client = if dry_run {
    @api.Client::new(base~)
  } else {
    // History is shipped in bulk; give the gateway room to take a batch.
    memory_client(selected).with_timeout(120_000)
  }
  let report = @importer.run(options, client)
  let text = StringBuilder()
  text.write_string("everme import sessions\n")
  text.write_string("  store    \{store}\n")
  for session in report.sessions {
    if session.turns > 0 {
      text.write_string(
        "  \{session.turns} turns  \{session.id}  — \{session.state}\n",
      )
    } else {
      text.write_string("           \{session.id}  — \{session.state}\n")
    }
  }
  text.write_string(
    "\n\{if dry_run { "would import" } else { "imported" }} \{report.imported_sessions} session(s), \{report.imported_turns} turn(s)\{if dry_run { "" } else { " in \{report.batches} batch(es)" }}\n",
  )
  if !dry_run && report.imported_turns > 0 {
    text.write_string(
      "Next: extraction runs in the background, so results appear over the next few minutes; `everme mcp test` shows the profile as it is now.\n",
    )
  }
  let data : Json = {
    "store": Json(store),
    "dryRun": Json(dry_run),
    "importedSessions": Json(report.imported_sessions),
    "importedTurns": Json(report.imported_turns),
    "batches": Json(report.batches),
    "sessions": Json(
      report.sessions.map(session => {
        "id": Json(session.id),
        "turns": Json(session.turns),
        "state": Json(session.state),
      }),
    ),
  }
  emit(machine, text.to_string(), data)
  0
}
