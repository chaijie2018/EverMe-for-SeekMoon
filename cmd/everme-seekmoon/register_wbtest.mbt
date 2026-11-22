// The pieces of the registration path that can be checked without a backend:
// what counts as success, what counts as "already registered", and the hint a
// rejected label leaves the user with.
//
// Whitebox on purpose: these are helpers of the `everme-seekmoon` binary's own package,
// and a main package should not grow a blackbox test surface.

///|
test "a success envelope is recognised without trusting the status alone" {
  let ok : @api.Exchange = {
    http_status: 200,
    envelope: {
      status: 0,
      error: "ok",
      request_id: "req_2",
      result: Json::null(),
    },
  }
  assert_true(exchange_ok(ok))
  let refused : @api.Exchange = {
    http_status: 200,
    envelope: {
      status: 20004,
      error: "platform: seekmoon does not validate as known_platform",
      request_id: "req_3",
      result: Json::null(),
    },
  }
  assert_false(exchange_ok(refused))
}

///|
test "a connected agent counts as already registered, a disconnected one does not" {
  let items : Array[Json] = [
    { "id": "a", "connectionStatus": "disconnected" },
    { "id": "b", "connectionStatus": "connected" },
    { "id": "c" },
  ]
  assert_eq(connected_agents(items), 2)
}

///|
test "no rows means nothing is registered" {
  assert_eq(connected_agents([]), 0)
}

///|
test "the rejected-label hint names the label that is known to work" {
  let hint = label_hint()
  assert_true(hint.contains("evercli"))
  assert_true(hint.contains("--platform"))
}

///|
fn stored_creds(
  api_key : String,
  agent_token : String,
  agent_id : String,
) -> @creds.Credentials {
  {
    api_key,
    agent_token,
    agent_id,
    platform: if agent_token.is_empty() { "" } else { "evercli" },
    token_prefix: "",
  }
}

///|
test "a login to another account drops the agent this CLI had" {
  let creds = stored_creds("emk_old", "evt_old", "agt_old")
  apply_login(creds, "emk_new", "", "")
  assert_eq(creds.api_key, "emk_new")
  assert_false(creds.has_agent_token())
  assert_eq(creds.agent_id, "")
  assert_eq(creds.platform, "")
}

///|
test "a login to the same account keeps the agent it already had" {
  let creds = stored_creds("emk_same", "evt_same", "agt_same")
  apply_login(creds, "emk_same", "", "")
  assert_true(creds.has_agent_token())
  assert_eq(creds.agent_id, "agt_same")
  assert_eq(creds.platform, "evercli")
}

///|
test "an agent that comes with the login replaces the stored one" {
  let creds = stored_creds("emk_a", "evt_old", "agt_old")
  apply_login(creds, "emk_a", "evt_new", "agt_new")
  assert_eq(creds.agent_token, "evt_new")
  assert_eq(creds.agent_id, "agt_new")
}

///|
async test "a write failure comes back as a reason instead of an exception" {
  let creds = stored_creds("emk_a", "evt_a", "agt_a")
  let dir = @fs.tmpdir(prefix="everme-seekmoon-store-")
  let path = dir + "/credentials.json"
  match try_store(path, creds) {
    Ok(_) => assert_true(@fs.exists(path) catch { _ => false })
    Err(reason) => fail("expected the credential to be written: \{reason}")
  }
  // A directory that cannot hold a file, which is what a wrong permission or a
  // read-only home looks like from here.
  match try_store("/dev/null/credentials.json", creds) {
    Ok(_) => fail("writing under /dev/null should not succeed")
    Err(_) => ()
  }
  @fs.remove(path) catch {
    _ => ()
  }
}

///|
test "a first login has no agent to inherit" {
  let creds = stored_creds("", "", "")
  apply_login(creds, "emk_first", "", "")
  assert_eq(creds.api_key, "emk_first")
  assert_false(creds.has_agent_token())
}

///|
async test "only one process can hold the registration lock at a time" {
  let dir = @fs.tmpdir(prefix="everme-seekmoon-lock-")
  let path = dir + "/credentials.json.lock"
  let first = registration_lock(path)
  let second = @fs.open(path, mode=WriteOnly, create_mode=OpenOrCreate)
  let blocked = second.try_lock(Exclusive) catch { _ => true }
  assert_false(blocked)
  second.close()
  first.close()
  // Released with the holder, not with the file: the next run can take it.
  let third = registration_lock(path)
  third.close()
  @fs.remove(path) catch {
    _ => ()
  }
}
