// The rendering contract: section headers the model can tell apart, one line per
// row, the provisional banner over raw transcript, and an empty string (not a
// stub) when nothing matched.

///|
/// A bundle with one row of each kind.
fn sample_bundle() -> @api.SearchBundle {
  {
    memories: [
      {
        "type": "episodic_memory",
        "episode": "User asked about X.\nResolved by Y.",
      },
    ],
    profiles: [
      { "profileData": { "embed_text": "Prefers Go", "item_type": "trait" } },
    ],
    raw_messages: [
      {
        "senderName": "user",
        "contentItems": [{ "text": "hi" }, { "text": "there" }],
      },
    ],
    skills: [{ "name": "toml-fix", "description": "Patch quoting in TOML" }],
    cases: [{ "taskIntent": "Fix parser", "approach": "Edited quotes" }],
    request_id: "req_1",
  }
}

///|
test "each kind gets its own section, in the documented order" {
  let text = @render.search_markdown(sample_bundle())
  assert_true(text.has_prefix("## Relevant memory\n\n### Episodic memory\n"))
  let episodic = text.find("### Episodic memory")
  let profile = text.find("### User profile")
  let skills = text.find("### Agent skills")
  let cases = text.find("### Past task cases")
  let raw = text.find("### Recent unextracted transcript")
  assert_true(episodic is Some(_) && profile is Some(_) && skills is Some(_))
  assert_true(cases is Some(_) && raw is Some(_))
  assert_true(episodic.unwrap() < profile.unwrap())
  assert_true(profile.unwrap() < skills.unwrap())
  assert_true(skills.unwrap() < cases.unwrap())
  assert_true(cases.unwrap() < raw.unwrap())
}

///|
test "a row is one line with whitespace collapsed" {
  let text = @render.search_markdown(sample_bundle())
  assert_true(text.contains("- [episodic] User asked about X. Resolved by Y."))
  assert_false(text.contains("X.\nResolved"))
}

///|
test "a profile row is tagged by its item type" {
  let text = @render.search_markdown(sample_bundle())
  assert_true(text.contains("- [trait] Prefers Go"))
}

///|
test "skills, cases, and raw rows keep their documented shapes" {
  let text = @render.search_markdown(sample_bundle())
  assert_true(text.contains("- [skill] toml-fix — Patch quoting in TOML"))
  assert_true(text.contains("- [case] Fix parser — Edited quotes"))
  assert_true(text.contains("- [raw user] hi there"))
}

///|
test "the provisional banner is verbatim, so rows are never quoted as fact" {
  let text = @render.search_markdown(sample_bundle())
  assert_true(
    text.contains(
      "### Recent unextracted transcript — provisional, not a stable memory",
    ),
  )
}

///|
test "an empty bundle renders as no text at all" {
  let empty : @api.SearchBundle = {
    memories: [],
    profiles: [],
    raw_messages: [],
    skills: [],
    cases: [],
    request_id: "",
  }
  assert_eq(@render.search_markdown(empty), "")
}

///|
test "a row longer than the cap is cut, as upstream does" {
  let long : @api.SearchBundle = {
    memories: [{ "type": "episodic", "episode": String::make(400, 'x') }],
    profiles: [],
    raw_messages: [],
    skills: [],
    cases: [],
    request_id: "",
  }
  let text = @render.search_markdown(long)
  assert_eq(
    text.length(),
    "## Relevant memory\n\n### Episodic memory\n- [episodic] ".length() + 280,
  )
}

///|
test "a pre-rendered context is passed through untouched" {
  let bundle : @api.ContextBundle = {
    context: "```memory\n## Relevant memory\n- [trait] Prefers Go\n```",
    profile: None,
    memory_count: 1,
    request_id: "req_2",
  }
  assert_eq(
    @render.profile_markdown(bundle),
    "```memory\n## Relevant memory\n- [trait] Prefers Go\n```",
  )
}

///|
test "a structured profile is rendered when there is no context" {
  let bundle : @api.ContextBundle = {
    context: "",
    profile: Some({
      "explicit_info": [{ "category": "tool", "description": "Uses MoonBit" }],
      "implicit_traits": [{ "trait": "style", "description": "Concise" }],
    }),
    memory_count: 2,
    request_id: "req_3",
  }
  let text = @render.profile_markdown(bundle)
  assert_true(text.has_prefix("```memory\n## Relevant memory\n"))
  assert_true(text.contains("- [tool] Uses MoonBit"))
  assert_true(text.contains("- style: Concise"))
}

///|
test "an empty profile renders as no text" {
  let bundle : @api.ContextBundle = {
    context: "",
    profile: None,
    memory_count: 0,
    request_id: "",
  }
  assert_eq(@render.profile_markdown(bundle), "")
}
