// The credential store's two jobs: write a file only this user can read, and
// read back what an earlier run (or the upstream CLI) left there.

///|
/// Delete `dir` and everything under it. `@fs.remove` refuses a non-empty
/// directory and `rmdir` is deprecated, so the tree is walked breadth-first here
/// — test cleanup should not be the one place that needs a deprecated API.
async fn purge(dir : String) -> Unit {
  let entries = @fs.readdir(dir) catch { _ => return }
  for entry in entries {
    let path = dir + "/" + entry
    let kind = @fs.kind(path) catch { _ => Unknown }
    if kind is Directory {
      purge(path)
    }
    @fs.remove(path) catch {
      _ => ()
    }
  }
  @fs.remove(dir) catch {
    _ => ()
  }
}

///|
/// A token-shaped secret, so the tests exercise real-looking values.
let sample_api_key : String = "emk_507d1234567890abcdef1234567890ab"

///|
/// An agent-token-shaped secret.
let sample_agent_token : String = "evt_abcd1234567890abcdef1234567890ab"

///|
async test "credentials round-trip through the store" {
  let dir = @fs.tmpdir(prefix="everme-seekmoon-creds-")
  defer @async.protect_from_cancel(() => purge(dir))
  let path = dir + "/credentials.json"
  let creds : @creds.Credentials = {
    api_key: sample_api_key,
    agent_token: sample_agent_token,
    agent_id: "agt_1",
    platform: "codex",
    token_prefix: "evt_abcd",
  }
  creds.save(path)
  let loaded = @creds.Credentials::load(path)
  assert_eq(loaded.api_key, sample_api_key)
  assert_eq(loaded.agent_token, sample_agent_token)
  assert_eq(loaded.agent_id, "agt_1")
  assert_eq(loaded.platform, "codex")
  assert_eq(loaded.token_prefix, "evt_abcd")
  assert_true(loaded.has_api_key())
  assert_true(loaded.has_agent_token())
}

///|
async test "an absent store reads as empty rather than failing" {
  let dir = @fs.tmpdir(prefix="everme-seekmoon-creds-")
  defer @async.protect_from_cancel(() => purge(dir))
  let loaded = @creds.Credentials::load(dir + "/missing.json")
  assert_false(loaded.has_api_key())
  assert_false(loaded.has_agent_token())
  assert_eq(loaded.agent_id, "")
}

///|
async test "a corrupt store reads as empty so login can repair it" {
  let dir = @fs.tmpdir(prefix="everme-seekmoon-creds-")
  defer @async.protect_from_cancel(() => purge(dir))
  let path = dir + "/credentials.json"
  @fs.write_text(path, "{not json")
  assert_false(@creds.Credentials::load(path).has_api_key())
}

///|
async test "no temp file is left behind by a save" {
  let dir = @fs.tmpdir(prefix="everme-seekmoon-creds-")
  defer @async.protect_from_cancel(() => purge(dir))
  let path = dir + "/credentials.json"
  let creds : @creds.Credentials = {
    api_key: sample_api_key,
    agent_token: "",
    agent_id: "",
    platform: "",
    token_prefix: "",
  }
  creds.save(path)
  let leftovers = @fs.readdir(dir)
  assert_eq(leftovers, ["credentials.json"])
}

///|
test "the summary never shows a usable secret" {
  let creds : @creds.Credentials = {
    api_key: sample_api_key,
    agent_token: sample_agent_token,
    agent_id: "agt_1",
    platform: "codex",
    token_prefix: "evt_abcd",
  }
  let summary = creds.summary()
  assert_false(summary.contains(sample_api_key))
  assert_false(summary.contains(sample_agent_token))
  assert_true(summary.contains("emk_507d_REDACTED"))
  assert_true(summary.contains("evt_abcd_REDACTED"))
}

///|
async test "adopt-evercli takes the account key and never the agent token" {
  let home = @fs.tmpdir(prefix="everme-seekmoon-home-")
  defer @async.protect_from_cancel(() => purge(home))
  @fs.mkdir(home + "/.local/share/evercli", recursive=true)
  @fs.write_text(
    home + "/.local/share/evercli/credentials.json",
    "{\"api-key\":\"\{sample_api_key}\",\"agent-token\":\"\{sample_agent_token}\"}",
  )
  let adopted = @creds.adopt_evercli(home)
  guard adopted is Some(adopted) else { fail("expected an adopted credential") }
  assert_eq(adopted.api_key, sample_api_key)
  // The agent token in that file belongs to whichever agent evercli
  // registered; borrowing it would attribute our memories to that agent.
  assert_eq(adopted.agent_token, "")
  assert_eq(adopted.agent_id, "")
}

///|
async test "adopt-evercli refuses a file that only holds an agent token" {
  let home = @fs.tmpdir(prefix="everme-seekmoon-home-")
  defer @async.protect_from_cancel(() => purge(home))
  @fs.mkdir(home + "/.local/share/evercli", recursive=true)
  @fs.write_text(
    home + "/.local/share/evercli/credentials.json",
    "{\"agent-token\":\"\{sample_agent_token}\"}",
  )
  assert_true(@creds.adopt_evercli(home) is None)
}

///|
async test "adopt-evercli reports nothing when evercli never logged in" {
  let home = @fs.tmpdir(prefix="everme-seekmoon-home-")
  defer @async.protect_from_cancel(() => purge(home))
  assert_true(@creds.adopt_evercli(home) is None)
}

///|
async test "adopt-evercli tolerates a corrupt evercli file" {
  let home = @fs.tmpdir(prefix="everme-seekmoon-home-")
  defer @async.protect_from_cancel(() => purge(home))
  @fs.mkdir(home + "/.local/share/evercli", recursive=true)
  @fs.write_text(home + "/.local/share/evercli/credentials.json", "nope")
  assert_true(@creds.adopt_evercli(home) is None)
}

///|
async test "the machine id is stable across calls" {
  let dir = @fs.tmpdir(prefix="everme-seekmoon-machine-")
  defer @async.protect_from_cancel(() => purge(dir))
  let path = dir + "/machine.json"
  let first = @creds.machine_id(path)
  let second = @creds.machine_id(path)
  assert_true(first.length() >= 16)
  assert_eq(first, second)
}

///|
test "verify_agent accepts the agent our own registration minted" {
  let items : Array[Json] = [
    { "id": "agt_1", "platform": "codex", "tokenPrefix": "evt_abcd" },
  ]
  assert_true(@creds.verify_agent("agt_1", "evt_abcd", "codex", items) is Ok(_))
}

///|
test "verify_agent rejects a token that belongs to another agent" {
  let items : Array[Json] = [
    { "id": "agt_1", "platform": "codex", "tokenPrefix": "evt_zzzz" },
  ]
  let message = match @creds.verify_agent("agt_1", "evt_abcd", "codex", items) {
    Ok(_) => "accepted"
    Err(message) => message
  }
  assert_true(message.contains("not the one"))
}

///|
test "verify_agent rejects an agent missing from the account list" {
  let items : Array[Json] = [
    { "id": "agt_other", "platform": "codex", "tokenPrefix": "evt_abcd" },
  ]
  let message = match @creds.verify_agent("agt_1", "evt_abcd", "codex", items) {
    Ok(_) => "accepted"
    Err(message) => message
  }
  assert_true(message.contains("not in this account"))
}

///|
test "verify_agent rejects a platform mismatch" {
  let items : Array[Json] = [
    { "id": "agt_1", "platform": "workbuddy", "tokenPrefix": "evt_abcd" },
  ]
  let message = match @creds.verify_agent("agt_1", "evt_abcd", "codex", items) {
    Ok(_) => "accepted"
    Err(message) => message
  }
  assert_true(message.contains("belongs to platform"))
}

///|
test "verify_agent rejects an agent the backend reports as disconnected" {
  let items : Array[Json] = [
    {
      "id": "agt_1",
      "platform": "codex",
      "tokenPrefix": "evt_abcd",
      "connectionStatus": "disconnected",
    },
  ]
  let message = match @creds.verify_agent("agt_1", "evt_abcd", "codex", items) {
    Ok(_) => "accepted"
    Err(message) => message
  }
  assert_true(message.contains("disconnected"))
}

///|
test "verify_agent refuses a token whose owner is unknown" {
  let items : Array[Json] = [
    { "id": "agt_1", "platform": "codex", "tokenPrefix": "evt_abcd" },
  ]
  let message = match @creds.verify_agent("", "evt_abcd", "codex", items) {
    Ok(_) => "accepted"
    Err(message) => message
  }
  assert_true(message.contains("no agent id"))
}
