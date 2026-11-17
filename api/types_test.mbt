// Envelope decoding and failure classification decide what a user sees when
// the backend says no, so they are tested against the shapes EverMe actually
// returns — including the ones that are not the envelope at all.

///|
test "a success envelope exposes its result and request id" {
  let envelope = @api.decode_envelope(
    "{\"error\":\"ok\",\"requestId\":\"req_1\",\"status\":0,\"result\":{\"items\":[]}}",
    200,
  )
  assert_true(envelope.is_ok())
  assert_eq(envelope.request_id, "req_1")
  assert_eq(@api.int_field(envelope.result, "status"), 0)
}

///|
test "a failed envelope keeps the backend's own words" {
  let envelope = @api.decode_envelope(
    "{\"error\":\"invalid platform: seekmoon\",\"requestId\":\"req_2\",\"status\":40010,\"result\":null}",
    400,
  )
  assert_false(envelope.is_ok())
  let exchange : @api.Exchange = { http_status: 400, envelope, }
  let failure = @api.failure_of(exchange)
  assert_eq(failure.kind, "invalid_args")
  assert_eq(failure.message, "invalid platform: seekmoon")
  assert_eq(failure.code, 40010)
  assert_eq(failure.request_id, "req_2")
}

///|
test "a non-JSON body becomes an upstream failure, not a crash" {
  let outcome = try {
    ignore(@api.decode_envelope("<html>502 Bad Gateway</html>", 502))
    "no raise"
  } catch {
    @api.ApiError(failure) => failure.message
  }
  assert_true(outcome.contains("502"))
  assert_true(outcome.contains("non-JSON"))
}

///|
test "a token inside a non-JSON body is masked before it is reported" {
  let outcome = try {
    ignore(
      @api.decode_envelope(
        "proxy rejected evt_abcd1234567890abcdef1234567890ab", 400,
      ),
    )
    "no raise"
  } catch {
    @api.ApiError(failure) => failure.message
  }
  assert_false(outcome.contains("evt_abcd1234567890abcdef1234567890ab"))
  assert_true(outcome.contains("evt_abcd_REDACTED"))
}

///|
test "classification follows the documented error.type taxonomy" {
  assert_eq(@api.classify(401), "auth")
  assert_eq(@api.classify(403), "auth")
  assert_eq(@api.classify(404), "not_found")
  assert_eq(@api.classify(409), "conflict")
  assert_eq(@api.classify(429), "rate_limit")
  assert_eq(@api.classify(400), "invalid_args")
  assert_eq(@api.classify(500), "upstream")
  assert_eq(@api.classify(200), "upstream")
}

///|
test "a transport failure is a network kind with a masked message" {
  let failure = @api.network_failure(
    "connection reset for evt_abcd1234567890abcdef1234567890ab",
  )
  assert_eq(failure.kind, "network")
  assert_false(failure.message.contains("evt_abcd1234567890abcdef1234567890ab"))
}

///|
test "typed field readers are total" {
  let json : Json = {
    "s": "text",
    "n": 42,
    "b": true,
    "a": ["x", "y"],
    "wrong": 7,
  }
  assert_eq(@api.string_field(json, "s"), "text")
  assert_eq(@api.string_field(json, "missing"), "")
  assert_eq(@api.string_field(json, "wrong"), "")
  assert_eq(@api.int_field(json, "n"), 42)
  assert_eq(@api.int_field(json, "s"), 0)
  assert_true(@api.bool_field(json, "b"))
  assert_false(@api.bool_field(json, "missing"))
  assert_eq(@api.strings_field(json, "a"), ["x", "y"])
  assert_eq(@api.strings_field(json, "missing"), [])
}

///|
test "a device flow decodes into the fields a user needs" {
  let result : Json = {
    "deviceCode": "dc_1",
    "userCode": "ABCD-1234",
    "verificationUrl": "https://evermind.ai/device",
    "expiresIn": 300,
    "interval": 5,
  }
  assert_eq(@api.string_field(result, "userCode"), "ABCD-1234")
  assert_eq(@api.int_field(result, "expiresIn"), 300)
}
