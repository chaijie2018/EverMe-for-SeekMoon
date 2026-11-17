// Token redaction is a public contract of EverMe, so it gets the strictest
// tests: a full credential must never survive, and a short prefix — which
// support output is allowed to show — must never be mangled.

///|
test "a full emk token is truncated to its prefix" {
  assert_eq(
    @redact.mask("emk_507d1234567890abcdef1234567890ab"),
    "emk_507d_REDACTED",
  )
}

///|
test "a full evt token is truncated to its prefix" {
  assert_eq(
    @redact.mask("Authorization: Bearer evt_abcd1234567890abcdef1234567890ab"),
    "Authorization: Bearer evt_abcd_REDACTED",
  )
}

///|
test "a short prefix is left alone so support output stays readable" {
  assert_eq(@redact.mask("emk_507d"), "emk_507d")
  assert_eq(@redact.mask("evt_ab"), "evt_ab")
}

///|
test "several tokens in one message are all masked" {
  assert_eq(
    @redact.mask(
      "a emk_11112222333344445555666677778888 b evt_99990000111122223333444455556666 c",
    ),
    "a emk_1111_REDACTED b evt_9999_REDACTED c",
  )
}

///|
test "text without credentials is unchanged" {
  let text = "HTTP 500 upstream: requestId=req_1 (no secrets here)"
  assert_eq(@redact.mask(text), text)
}

///|
test "a token at the very end of the text is masked" {
  assert_eq(
    @redact.mask("failed for emk_aaaabbbbccccddddeeeeffff00001111"),
    "failed for emk_aaaa_REDACTED",
  )
}

///|
test "an empty secret renders as empty" {
  assert_eq(@redact.mask_one(""), "")
}
