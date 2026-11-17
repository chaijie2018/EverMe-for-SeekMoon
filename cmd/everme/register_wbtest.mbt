// The pieces of the registration path that can be checked without a backend:
// what counts as success, what counts as "already registered", and the hint a
// rejected label leaves the user with.
//
// Whitebox on purpose: these are helpers of the `everme` binary's own package,
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
