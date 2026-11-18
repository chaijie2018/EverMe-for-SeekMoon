// Markdown rendering for memory results.
//
// This is a faithful port of upstream's `plugins/agent-sdk/src/prompt.js`
// (`buildMemoryPrompt` and friends), because the shape is part of what hosts and
// skills expect: section headers the model can tell apart, one line per row, and
// a provisional banner over unextracted transcript rows so the model never quotes
// them as established facts. Row text is collapsed to one line and cut at 280
// characters — upstream cuts without an ellipsis, and matching it keeps the two
// implementations' output comparable.

///|
/// How long a rendered row may be, in characters.
const RowMaxChars : Int32 = 280

///|
/// The header over raw transcript rows. Kept word-for-word in sync with upstream
/// (`prompt.js`), because it is the only thing telling a model these rows are
/// provisional.
const ProvisionalHeader : String = "### Recent unextracted transcript — provisional, not a stable memory"

///|
/// Collapse every whitespace run to one space, trim, and cut at `RowMaxChars`.
fn one_line(text : String) -> String {
  let out = StringBuilder()
  let mut pending_space = false
  let mut written = false
  for ch in text {
    if ch is (' ' | '\t' | '\n' | '\r') {
      if written {
        pending_space = true
      }
    } else {
      if pending_space {
        out.write_char(' ')
        pending_space = false
      }
      out.write_char(ch)
      written = true
    }
  }
  let line = out.to_string()
  if line.length() > RowMaxChars {
    line[:RowMaxChars].to_owned()
  } else {
    line
  }
}

///|
/// The display label for a memory row's `type`.
fn type_label(kind : String) -> String {
  match kind {
    "episodic" | "episodic_memory" => "episodic"
    "profile" => "profile"
    "agent_memory" => "agent"
    "raw_message" => "recent"
    "" => "memory"
    other => other
  }
}

///|
/// `field` of `json`, or "" when it is absent or not a string.
fn text_field(json : Json, field : String) -> String {
  match json {
    Object(fields) =>
      match fields.get(field) {
        Some(String(value)) => value
        _ => ""
      }
    _ => ""
  }
}

///|
/// The first non-empty of `fields`, in order.
fn first_text(json : Json, fields : Array[String]) -> String {
  for field in fields {
    let value = text_field(json, field)
    if !value.is_empty() {
      return value
    }
  }
  ""
}

///|
/// One episodic row: `- [episodic] text`.
fn format_row(row : Json) -> String {
  let text = first_text(row, ["episode", "summary", "content", "text"])
  if text.is_empty() {
    return ""
  }
  "- [\{type_label(text_field(row, "type"))}] \{one_line(text)}"
}

///|
/// One profile row: `- [<item_type>] text`.
fn format_profile(row : Json) -> String {
  let data = match row {
    Object(fields) =>
      match fields.get("profileData") {
        Some(data) => data
        None => Json::empty_object()
      }
    _ => Json::empty_object()
  }
  let text = first_text(data, ["embed_text"])
  let text = if text.is_empty() { text_field(row, "summary") } else { text }
  if text.is_empty() {
    return ""
  }
  let tag = text_field(data, "item_type")
  let tag = if tag.is_empty() { "profile" } else { tag }
  "- [\{tag}] \{one_line(text)}"
}

///|
/// One agent skill: `- [skill] name — description`.
fn format_skill(row : Json) -> String {
  let name = text_field(row, "name")
  let name = if name.is_empty() { "(unnamed skill)" } else { name }
  let description = first_text(row, ["description", "content"])
  if description.is_empty() {
    "- [skill] \{name}"
  } else {
    "- [skill] \{name} — \{one_line(description)}"
  }
}

///|
/// One past task case: `- [case] intent — approach`.
fn format_case(row : Json) -> String {
  let intent = text_field(row, "taskIntent")
  let approach = text_field(row, "approach")
  if intent.is_empty() && approach.is_empty() {
    return ""
  }
  let head = if intent.is_empty() {
    "- [case]"
  } else {
    "- [case] \{one_line(intent)}"
  }
  if approach.is_empty() {
    head
  } else {
    "\{head} — \{one_line(approach)}"
  }
}

///|
/// The text of one raw transcript message, from its opaque `contentItems`.
fn raw_message_text(row : Json) -> String {
  let parts = match row {
    Object(fields) =>
      match fields.get("contentItems") {
        Some(Array(items)) => items
        _ => []
      }
    _ => []
  }
  let chunks : Array[String] = []
  for part in parts {
    match part {
      String(text) => chunks.push(text)
      Object(_) => {
        let text = first_text(part, ["text", "content"])
        if !text.is_empty() {
          chunks.push(text)
        }
      }
      _ => ()
    }
  }
  chunks.join(" ")
}

///|
/// One raw transcript row: `- [raw <sender>] text`.
fn format_raw_message(row : Json) -> String {
  let text = raw_message_text(row)
  if text.is_empty() {
    return ""
  }
  let sender = text_field(row, "senderName")
  let sender = if sender.is_empty() { "speaker" } else { sender }
  "- [raw \{sender}] \{one_line(text)}"
}

///|
/// `title` plus its lines, or `None` when there is nothing to show.
fn section(title : String, lines : Array[String]) -> String? {
  if lines.is_empty() {
    None
  } else {
    Some("\{title}\n\{lines.join("\n")}")
  }
}

///|
/// Format `rows` with `format`, dropping rows that render empty.
fn lines_of(rows : Array[Json], format : (Json) -> String) -> Array[String] {
  let out : Array[String] = []
  for row in rows {
    let line = format(row)
    if !line.is_empty() {
      out.push(line)
    }
  }
  out
}

///|
/// The body of a search: `## Relevant memory` followed by one section per kind
/// that has rows, or "" when nothing matched.
pub fn search_markdown(bundle : @api.SearchBundle) -> String {
  let parts : Array[String] = []
  let episodes = lines_of(bundle.memories, format_row)
  let profiles = lines_of(bundle.profiles, format_profile)
  let skills = lines_of(bundle.skills, format_skill)
  let cases = lines_of(bundle.cases, format_case)
  let raw = lines_of(bundle.raw_messages, format_raw_message)
  for
    candidate in [
      section("### Episodic memory", episodes),
      section("### User profile", profiles),
      section("### Agent skills", skills),
      section("### Past task cases", cases),
      section(ProvisionalHeader, raw),
    ] {
    if candidate is Some(text) {
      parts.push(text)
    }
  }
  if parts.is_empty() {
    return ""
  }
  "## Relevant memory\n\n\{parts.join("\n\n")}"
}

///|
/// The profile block: the backend's pre-rendered `context` when it has one,
/// otherwise the structured `profile` rendered the way upstream does.
pub fn profile_markdown(bundle : @api.ContextBundle) -> String {
  if !bundle.context.trim().is_empty() {
    return bundle.context
  }
  guard bundle.profile is Some(profile) else { return "" }
  let lines : Array[String] = []
  for row in @api.array_field(profile, "explicit_info") {
    let description = text_field(row, "description")
    if description.is_empty() {
      continue
    }
    let category = text_field(row, "category")
    let prefix = if category.is_empty() { "" } else { "[\{category}] " }
    lines.push("- \{prefix}\{one_line(description)}")
  }
  for row in @api.array_field(profile, "implicit_traits") {
    let description = text_field(row, "description")
    if description.is_empty() {
      continue
    }
    let trait_ = text_field(row, "trait")
    let prefix = if trait_.is_empty() { "" } else { "\{trait_}: " }
    lines.push("- \{prefix}\{one_line(description)}")
  }
  if lines.is_empty() {
    return ""
  }
  "```memory\n## Relevant memory\n\{lines.join("\n")}\n```"
}

///|
/// What to show when a search matched nothing, so the model sees an answer
/// rather than an empty string.
pub fn empty_search_note(query : String) -> String {
  "_(no memory matched \"\{one_line(query)}\")_"
}
