// Helpers for `everme-seekmoon mcp test`: the pieces a self-check needs to report what the
// server would answer, without the CLI having to reach into the decision enum.

///|
/// A short description of what `decide` would do — enough for a self-check line.
pub fn describe_decision(message : Json) -> String {
  match decide(message) {
    Nothing => "nothing"
    Answer(..) => "answer"
    Fail(code~, ..) => "fail(\{code})"
    Perform(..) => "perform"
  }
}

///|
/// The tool names this server advertises.
pub fn tool_names() -> Array[String] {
  let names : Array[String] = []
  for schema in tool_schemas() {
    names.push(text_field(schema, "name"))
  }
  names
}

///|
/// The text of a result's first content item (tool results), or its first
/// resource, or "" — the shape a caller wants to preview.
pub fn content_text(result : Json) -> String {
  for item in array_field(result, "content") {
    let text = text_field(item, "text")
    if !text.is_empty() {
      return text
    }
  }
  for item in array_field(result, "contents") {
    let text = text_field(item, "text")
    if !text.is_empty() {
      return text
    }
  }
  ""
}
