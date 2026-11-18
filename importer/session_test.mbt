// Parsing a session log. The fixture below is the real record shape, so these
// tests pin what actually gets sent: which kinds count as conversation, how tool
// calls are reshaped, and what a cursor means.

///|
/// One session with every record kind that matters, plus two that do not.
fn sample_log() -> String {
  let text =
    #|{"version":1,"id":"s1","system_prompt":"…"}
    #|{"sequence":1,"ts":1700000000000,"item":{"kind":"user","payload":{"content":"How do I fix the TOML parser?"}}}
    #|{"sequence":2,"ts":1700000001000,"item":{"kind":"assistant","payload":{"content":"","brief":"checking","tool_calls":[{"id":"call_1","name":"mbtx","arguments":"{\"source\":\"x\"}"}]}}}
    #|{"sequence":3,"ts":1700000002000,"item":{"kind":"tool_result","payload":{"tool_call_id":"call_1","tool_name":"mbtx","content":"it worked","is_error":false}}}
    #|{"sequence":4,"ts":1700000003000,"item":{"kind":"assistant","payload":{"content":"Use quotes.","brief":""}}}
    #|{"sequence":5,"ts":1700000004000,"item":{"kind":"runtime_notice","payload":{"kind":"x","message":"harness noise"}}}
    #|{"sequence":6,"ts":1700000005000,"item":{"kind":"terminal","payload":{"kind":"x","data":"more noise"}}}
    #|{"sequence":7,"ts":1700000006000,"item":{"kind":"user","payload":{"content":"   "}}}
  text
}

///|
test "only user, assistant, and tool_result become turns" {
  let turns = @importer.parse_turns(sample_log())
  assert_eq(turns.length(), 4)
  assert_eq(turns[0].role, "user")
  assert_eq(turns[0].content, "How do I fix the TOML parser?")
  assert_eq(turns[1].role, "assistant")
  assert_eq(turns[2].role, "tool")
  assert_eq(turns[3].role, "assistant")
}

///|
test "a tool call is reshaped into the gateway's function call" {
  let turns = @importer.parse_turns(sample_log())
  assert_eq(turns[1].tool_calls.length(), 1)
  let call = turns[1].tool_calls[0]
  assert_eq(@api.string_field(call, "id"), "call_1")
  assert_eq(@api.string_field(call, "type"), "function")
  assert_eq(@api.string_field(call, "name"), "mbtx")
  assert_eq(@api.string_field(call, "arguments"), "{\"source\":\"x\"}")
}

///|
test "an assistant turn with only tool calls keeps its brief text" {
  let turns = @importer.parse_turns(sample_log())
  assert_eq(turns[1].content, "checking")
}

///|
test "a tool result keeps its call id" {
  let turns = @importer.parse_turns(sample_log())
  assert_eq(turns[2].tool_call_id, "call_1")
  assert_eq(turns[2].content, "it worked")
}

///|
test "whitespace-only turns are dropped" {
  let turns = @importer.parse_turns(sample_log())
  let empty = turns.filter(turn => {
    turn.content.trim().is_empty() && turn.tool_calls.is_empty()
  })
  assert_eq(empty.length(), 0)
}

///|
test "sequence and timestamp survive" {
  let turns = @importer.parse_turns(sample_log())
  assert_eq(turns[0].sequence, 1)
  assert_eq(turns[3].sequence, 4)
  assert_eq(turns[0].timestamp, 1700000000000L)
}

///|
test "a message carries only the fields it has" {
  let turns = @importer.parse_turns(sample_log())
  let user = @importer.message_of(turns[0])
  assert_eq(@api.string_field(user, "role"), "user")
  assert_eq(@api.string_field(user, "content"), "How do I fix the TOML parser?")
  assert_eq(@api.string_field(user, "toolCallId"), "")
  let assistant = @importer.message_of(turns[1])
  assert_eq(@api.array_field(assistant, "toolCalls").length(), 1)
  let tool = @importer.message_of(turns[2])
  assert_eq(@api.string_field(tool, "toolCallId"), "call_1")
}

///|
test "a conversation id is namespaced so session ids cannot collide" {
  assert_eq(@importer.conversation_id("abc"), "openseek:abc")
}

///|
test "the cursor selects turns at or after it" {
  let turns = @importer.parse_turns(sample_log())
  assert_eq(@importer.since(turns, 0).length(), 4)
  assert_eq(@importer.since(turns, 3).length(), 2)
  assert_eq(@importer.since(turns, 9).length(), 0)
}

///|
test "the cursor advances to the last sequence seen" {
  let turns = @importer.parse_turns(sample_log())
  assert_eq(@importer.last_sequence(turns, 0), 4)
  assert_eq(@importer.last_sequence(turns, 10), 10)
  assert_eq(@importer.last_sequence([], 7), 7)
}

///|
test "a header-only or unreadable log yields no turns" {
  let header =
    #|{"version":1,"id":"s"}
  assert_eq(@importer.parse_turns(header).length(), 0)
  assert_eq(@importer.parse_turns("not json\n{}\n").length(), 0)
}

///|
test "an oversized turn is cut and marked" {
  let long = String::make(9000, 'x')
  let log = "{\"sequence\":1,\"ts\":1,\"item\":{\"kind\":\"user\",\"payload\":{\"content\":\"\{long}\"}}}"
  let turns = @importer.parse_turns(log)
  assert_eq(turns.length(), 1)
  assert_true(turns[0].content.has_suffix("…(truncated on import)"))
  assert_true(turns[0].content.length() < 9000)
}
