// The API base is user input (flag or environment) that decides where
// credentials get sent, so its normalization is worth pinning down: exactly
// one `/api/v1`, no trailing slash, and a refusal for anything that is not an
// http(s) URL.

///|
test "a bare origin gains the api prefix" {
  assert_eq(
    @config.api_root("https://api.everme.evermind.ai"),
    "https://api.everme.evermind.ai/api/v1",
  )
}

///|
test "a trailing slash is dropped before the prefix is added" {
  assert_eq(
    @config.api_root("https://api.everme.evermind.ai/"),
    "https://api.everme.evermind.ai/api/v1",
  )
}

///|
test "an existing prefix is kept, not doubled" {
  assert_eq(
    @config.api_root("https://api.everme.evermind.ai/api/v1"),
    "https://api.everme.evermind.ai/api/v1",
  )
  assert_eq(@config.api_root("https://host/api/v2/"), "https://host/api/v2")
}

///|
test "a self-hosted origin with a port works" {
  assert_eq(
    @config.api_root("http://127.0.0.1:8080"),
    "http://127.0.0.1:8080/api/v1",
  )
}

///|
test "a path that merely contains api is still given the prefix" {
  assert_eq(
    @config.api_root("https://host/apiary"),
    "https://host/apiary/api/v1",
  )
}

///|
test "a non-http base is refused" {
  let outcome = @config.api_root("ftp://host") catch { _ => "raised" }
  assert_eq(outcome, "raised")
}

///|
test "the default platform is the label the managed backend accepts" {
  // `seekmoon` was verified to be refused (`status=20004`,
  // "does not validate as known_platform"), so the default is the label that
  // works; `--platform` overrides it once upstream whitelists the real name.
  assert_eq(@config.DefaultPlatform, "evercli")
}
