// Importing session logs: discover, filter by the cursor, send, remember.
//
// The cursor is what makes this safe to run repeatedly: it records, per session,
// the next sequence to send, so a second run imports only what was appended since.
// A session that was rewritten shorter simply has nothing new.

///|
/// What to import, and from where.
pub(all) struct ImportOptions {
  /// A session store: `…/.openseek/sessions`.
  store : String
  /// Where the per-session cursor lives.
  state_file : String
  /// Skip sessions whose file has not changed in this many days (0 = all).
  since_days : Int32
  /// Import at most this many sessions (0 = all).
  limit : Int32
  /// Turns per request. Below the gateway's 500 cap on purpose: a batch of long
  /// turns is megabytes, and a request that times out would lose the whole
  /// session's progress without a per-batch cursor.
  batch_size : Int32
  /// Count only.
  dry_run : Bool
}

///|
/// One session's outcome.
pub(all) struct SessionReport {
  id : String
  turns : Int32
  state : String
}

///|
/// The whole run.
pub(all) struct ImportReport {
  store : String
  sessions : Array[SessionReport]
  imported_sessions : Int32
  imported_turns : Int32
  batches : Int32
}

///|
/// The `sessions` object of a state document, as plain numbers.
fn sessions_of(json : Json) -> Array[(String, Int32)] {
  let out : Array[(String, Int32)] = []
  match json {
    Object(fields) =>
      match fields.get("sessions") {
        Some(Object(sessions)) =>
          for id, value in sessions {
            if value is Number(count, ..) {
              out.push((id, count.to_int()))
            }
          }
        _ => ()
      }
    _ => ()
  }
  out
}

///|
/// The next-sequence cursor per session id.
async fn load_state(path : String) -> Map[String, Int32] {
  let state : Map[String, Int32] = Map([])
  let text = @fs.read_text(path) catch { _ => return state }
  let json : Json = @json.parse(text) catch { _ => return state }
  for entry in sessions_of(json) {
    let (id, next) = entry
    state[id] = next
  }
  state
}

///|
/// Persist the cursor.
async fn save_state(path : String, state : Map[String, Int32]) -> Unit {
  let sessions : Map[String, Json] = Map([])
  for id, next in state {
    sessions[id] = Json(next)
  }
  let document : Json = { "sessions": Json::object(sessions) }
  let parent = match path.rev_split_once("/") {
    Some((dir, _)) => if dir.is_empty() { "/" } else { dir.to_owned() }
    None => "."
  }
  @fs.mkdir(parent, recursive=true) catch {
    _ => ()
  }
  @fs.write_text(path, document.stringify()) catch {
    error =>
      raise @api.ApiError({
        kind: "io",
        message: "cannot write the import cursor at \{path}: \{error}",
        hint: "check permissions on that directory",
        http_status: 0,
        code: 0,
        request_id: "",
      })
  }
}

///|
/// The session log path inside a session directory, or `None` when this directory
/// is not one (the store also holds scratch directories).
async fn log_of(store : String, id : String) -> String? {
  let path = store + "/" + id + "/openseek_session-" + id + ".jsonl"
  let exists = @fs.exists(path) catch { _ => false }
  if exists {
    Some(path)
  } else {
    None
  }
}

///|
/// Whether `path` was modified within `since_days` (always true for 0).
async fn recently_modified(path : String, since_days : Int32) -> Bool {
  if since_days <= 0 {
    return true
  }
  let modified = @fs.mtime(path) catch { _ => return true }
  let now : Int64 = @env.now().reinterpret_as_int64()
  let age_ms = now - modified.msec()
  age_ms <= since_days.to_int64() * 86_400_000
}

///|
/// Import every session with something new. Returns what each session came to, so
/// a dry run and a real run read the same.
pub async fn run(options : ImportOptions, client : @api.Client) -> ImportReport {
  let state = load_state(options.state_file)
  let ids = @fs.readdir(options.store, sort=true) catch { _ => [] }
  let reports : Array[SessionReport] = []
  let mut imported_sessions = 0
  let mut imported_turns = 0
  let mut batches = 0
  for id in ids {
    if options.limit > 0 && imported_sessions >= options.limit {
      break
    }
    guard log_of(options.store, id) is Some(path) else { continue }
    if !recently_modified(path, options.since_days) {
      reports.push({ id, turns: 0, state: "skipped (not modified recently)", })
      continue
    }
    let text = @fs.read_text(path) catch {
      error => {
        reports.push({ id, turns: 0, state: "skipped (unreadable: \{error})", })
        continue
      }
    }
    let turns = parse_turns(text)
    let cursor = state.get(id).unwrap_or(0)
    let fresh = since(turns, cursor)
    if fresh.is_empty() {
      reports.push({ id, turns: 0, state: "up to date", })
      continue
    }
    if options.dry_run {
      reports.push({ id, turns: fresh.length(), state: "would import", })
      imported_sessions = imported_sessions + 1
      imported_turns = imported_turns + fresh.length()
      continue
    }
    // One batch at a time, advancing the cursor after each: a long session makes
    // visible progress, and a failure at batch N keeps 1..N-1 imported.
    let mut index = 0
    while index < fresh.length() {
      let end = (index + options.batch_size).min(fresh.length())
      let messages : Array[Json] = []
      for position in index..<end {
        messages.push(message_of(fresh[position]))
      }
      let is_last = end == fresh.length()
      let saved = client.save_agent_memory(
        conversation_id=conversation_id(id),
        messages~,
        flush=is_last,
        batch_size=options.batch_size,
      ) catch {
        @api.ApiError(failure) =>
          raise @api.ApiError({
            kind: failure.kind,
            message: "importing \{id} failed at turn \{fresh[index].sequence}: \{failure.message}",
            hint: failure.hint,
            http_status: failure.http_status,
            code: failure.code,
            request_id: failure.request_id,
          })
      }
      ignore(saved)
      batches = batches + 1
      state[id] = fresh[end - 1].sequence + 1
      save_state(options.state_file, state)
      index = end
    }
    imported_sessions = imported_sessions + 1
    imported_turns = imported_turns + fresh.length()
    reports.push({ id, turns: fresh.length(), state: "imported", })
  }
  {
    store: options.store,
    sessions: reports,
    imported_sessions,
    imported_turns,
    batches,
  }
}
