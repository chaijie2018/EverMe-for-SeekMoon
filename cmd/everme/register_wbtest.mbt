// The label negotiation is the only place this CLI retries a rejected request,
// so both halves of that rule are pinned down here: which labels get tried, and
// which failures are allowed to trigger another try.
//
// Whitebox on purpose: these are helpers of the `everme` binary's own package,
// and a main package should not grow a blackbox test surface.

///|
test "the wanted label is tried first, then the fallback" {
  assert_eq(platform_candidates("seekmoon", "evercli"), ["seekmoon", "evercli"])
}

///|
test "a repeated or blank label is not tried twice" {
  assert_eq(platform_candidates("evercli", "evercli"), ["evercli"])
  assert_eq(platform_candidates("", "evercli"), ["evercli"])
  assert_eq(platform_candidates("seekmoon", ""), ["seekmoon"])
  assert_eq(platform_candidates("", ""), [])
}

///|
test "only a value rejection retries under another label" {
  let rejected : @api.Failure = {
    kind: "invalid_args",
    message: "platform: seekmoon does not validate as known_platform",
    hint: "",
    http_status: 400,
    code: 20004,
    request_id: "req_1",
  }
  assert_true(label_rejected(rejected))
}

///|
test "a network, auth, throttling, or server failure does not retry" {
  for kind in ["network", "auth", "rate_limit", "upstream", "conflict"] {
    let failure : @api.Failure = {
      kind,
      message: "unrelated to the label",
      hint: "",
      http_status: 500,
      code: 0,
      request_id: "",
    }
    assert_false(label_rejected(failure))
  }
}

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
