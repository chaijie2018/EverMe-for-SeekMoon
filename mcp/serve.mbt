// The stdio loop. One NDJSON message per line in, one per line out; stdout
// carries protocol frames only, so anything diagnostic goes to stderr and only
// when `EVERME_DEBUG=1`.
//
// The loop itself is three lines of policy — read, decide, answer — because
// `decide` (pure) and `execute` (backend) already own the interesting parts.

///|
/// The environment variable that turns on stderr logging.
const DebugEnv : String = "EVERME_DEBUG"

///|
/// A line that did not parse. JSON-RPC wants `id: null` for a parse error.
pub fn parse_failure() -> Json {
  parse_error_reply("the request was not valid JSON")
}

///|
/// Whether debug logging is on.
fn debugging() -> Bool {
  match @env.get_env_var(DebugEnv) {
    Some(value) => !value.trim().is_empty() && value.trim() != "0"
    None => false
  }
}

///|
/// Log to stderr, never to stdout.
async fn log(text : String) -> Unit {
  if debugging() {
    @stdio.stderr.text.write("[everme-mcp] \{text}\n") catch {
      _ => ()
    }
  }
}

///|
/// Write one protocol frame.
async fn write_json(value : Json) -> Unit {
  let line = value.stringify() + "\n"
  @stdio.stdout.text.write(line) catch {
    _ => ()
  }
}

///|
/// Answer one decoded message.
async fn handle(message : Json, client : @api.Client) -> Unit {
  match decide(message) {
    Nothing => log("notification")
    Answer(id~, result~) => write_json(reply(id, result))
    Fail(id~, code~, message~) => write_json(error_reply(id, code, message))
    Perform(id~, action~, as_tool~) =>
      match execute(action, client) {
        Ok(result) => write_json(reply(id, result))
        Err(message) =>
          if as_tool {
            write_json(reply(id, tool_error(message)))
          } else {
            write_json(error_reply(id, CodeInternal, message))
          }
      }
  }
}

///|
/// Serve MCP over stdin/stdout until the host closes the connection (EOF). A
/// line that is not JSON is answered with a parse error and the loop continues:
/// a wedged frame must not take the session down with it.
pub async fn serve(client : @api.Client) -> Unit {
  log("serving")
  for ;; {
    let line = @stdio.stdin.text.read_until("\n") catch { _ => None }
    guard line is Some(line) else { break }
    let text = line.trim(chars="\r\n")
    if text.is_empty() {
      continue
    }
    let parsed : Json? = Some(@json.parse(text)) catch { _ => None }
    match parsed {
      None => write_json(parse_failure())
      Some(message) => handle(message, client)
    }
  }
  log("stdin closed")
}
