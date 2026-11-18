// The method table, exercised as a pure function: every arm of `decide` is
// checked here, which is what keeps the protocol layer trustworthy without a
// backend, a subprocess, or a network.

///|
/// The decision for one request.
fn decision_for(verb : String, params : Json) -> Decision {
  decide({ "jsonrpc": "2.0", "id": 1, "method": Json(verb), "params": params })
}

///|
/// The result of a request the server can answer alone.
fn answer_for(verb : String, params : Json) -> Json raise {
  match decision_for(verb, params) {
    Answer(result~, ..) => result
    _ => fail("expected an immediate answer for \{verb}")
  }
}

///|
test "tools/list advertises the four memory tools" {
  let result = answer_for("tools/list", Json::empty_object())
  assert_eq(tool_names(), [
    "mem_context", "mem_search", "mem_save_fact", "mem_save_turn",
  ])
  assert_eq(@api.array_field(result, "tools").length(), 4)
}

///|
test "resources/list and the template list name the documented URIs" {
  let listed = answer_for("resources/list", Json::empty_object())
  let resources = @api.array_field(listed, "resources")
  assert_eq(resources.length(), 1)
  assert_eq(@api.string_field(resources[0], "uri"), "mem://profile")
  let templates = answer_for("resources/templates/list", Json::empty_object())
  let template = @api.array_field(templates, "resourceTemplates")[0]
  assert_eq(
    @api.string_field(template, "uriTemplate"),
    "mem://search?q={query}&topK={topK}",
  )
}

///|
test "initialize echoes the client's protocol version and carries instructions" {
  let result = answer_for("initialize", { "protocolVersion": "2025-06-18" })
  assert_eq(@api.string_field(result, "protocolVersion"), "2025-06-18")
  assert_true(@api.string_field(result, "instructions").contains("mem_context"))
}

///|
test "an unversioned initialize falls back to a legacy version" {
  let result = answer_for("initialize", Json::empty_object())
  assert_eq(@api.string_field(result, "protocolVersion"), "2024-11-05")
}

///|
test "server/discover is method-not-found, so a modern client falls back" {
  match decision_for("server/discover", Json::empty_object()) {
    Fail(code~, ..) => assert_eq(code, CodeMethodNotFound)
    _ => fail("expected a method-not-found failure")
  }
}

///|
test "an unknown method is method-not-found too" {
  match decision_for("mcp/nonsense", Json::empty_object()) {
    Fail(code~, ..) => assert_eq(code, CodeMethodNotFound)
    _ => fail("expected a method-not-found failure")
  }
}

///|
test "a notification and a stray response need no answer" {
  assert_true(
    decide({ "jsonrpc": "2.0", "method": "notifications/initialized" })
    is Nothing,
  )
  assert_true(
    decide({ "jsonrpc": "2.0", "id": 7, "result": Json::null() }) is Nothing,
  )
}

///|
test "ping is answered inline" {
  let result = answer_for("ping", Json::empty_object())
  assert_true(result is Object(fields) && fields.is_empty())
}

///|
test "mem_search without a query is a tool error, never a backend call" {
  match
    decision_for("tools/call", {
      "name": "mem_search",
      "arguments": Json::empty_object(),
    }) {
    Answer(result~, ..) => {
      assert_true(@api.bool_field(result, "isError"))
      assert_true(content_text(result).contains("non-empty `query`"))
    }
    _ => fail("expected an immediate tool error")
  }
}

///|
test "mem_search clamps its query and its topK" {
  let long_query = String::make(2000, 'x')
  match
    decision_for("tools/call", {
      "name": "mem_search",
      "arguments": { "query": Json(long_query), "topK": 999 },
    }) {
    Perform(action~, as_tool~, ..) => {
      assert_true(as_tool)
      match action {
        Search(query~, top_k~) => {
          assert_eq(top_k, @api.TopKMax)
          assert_eq(query.length(), @api.QueryMaxChars)
        }
        _ => fail("expected a search action")
      }
    }
    _ => fail("expected a search")
  }
}

///|
test "a non-positive topK falls back to the default" {
  match
    decision_for("tools/call", {
      "name": "mem_search",
      "arguments": { "query": "toml", "topK": 0 },
    }) {
    Perform(action~, ..) =>
      match action {
        Search(top_k~, ..) => assert_eq(top_k, @api.TopKDefault)
        _ => fail("expected a search action")
      }
    _ => fail("expected a search")
  }
}

///|
test "mem_context defaults to the cached profile" {
  match decision_for("tools/call", { "name": "mem_context" }) {
    Perform(action~, ..) =>
      match action {
        Context(force_refresh~) => assert_false(force_refresh)
        _ => fail("expected a context action")
      }
    _ => fail("expected a context action")
  }
}

///|
test "mem_save_fact turns a fact into one user turn, flushed by default" {
  match
    decision_for("tools/call", {
      "name": "mem_save_fact",
      "arguments": { "fact": "Prefers tabs" },
    }) {
    Perform(action~, ..) =>
      match action {
        SaveFact(messages~, session_key~, flush~) => {
          assert_eq(messages.length(), 1)
          assert_eq(@api.string_field(messages[0], "role"), "user")
          assert_eq(@api.string_field(messages[0], "content"), "Prefers tabs")
          assert_eq(session_key, "default")
          assert_true(flush)
        }
        _ => fail("expected a save-fact action")
      }
    _ => fail("expected a save-fact action")
  }
}

///|
test "mem_save_fact refuses a tool turn and points at mem_save_turn" {
  match
    decision_for("tools/call", {
      "name": "mem_save_fact",
      "arguments": { "messages": [{ "role": "tool", "content": "result" }] },
    }) {
    Answer(result~, ..) => {
      assert_true(@api.bool_field(result, "isError"))
      assert_true(content_text(result).contains("use mem_save_turn"))
    }
    _ => fail("expected an immediate tool error")
  }
}

///|
test "mem_save_fact without fact or messages is a tool error" {
  match decision_for("tools/call", { "name": "mem_save_fact" }) {
    Answer(result~, ..) =>
      assert_true(content_text(result).contains("either `fact`"))
    _ => fail("expected an immediate tool error")
  }
}

///|
test "mem_save_turn accepts the single-turn shorthand" {
  match
    decision_for("tools/call", {
      "name": "mem_save_turn",
      "arguments": { "role": "assistant", "text": "done" },
    }) {
    Perform(action~, ..) =>
      match action {
        SaveTurn(messages~, ..) => {
          assert_eq(messages.length(), 1)
          assert_eq(@api.string_field(messages[0], "role"), "assistant")
        }
        _ => fail("expected a save-turn action")
      }
    _ => fail("expected a save-turn action")
  }
}

///|
test "mem_save_turn keeps tool results and their call ids" {
  match
    decision_for("tools/call", {
      "name": "mem_save_turn",
      "arguments": {
        "messages": [
          { "role": "user", "content": "q" },
          { "role": "toolResult", "toolCallId": "call_1", "content": "r" },
        ],
      },
    }) {
    Perform(action~, ..) =>
      match action {
        SaveTurn(messages~, ..) => {
          assert_eq(messages.length(), 2)
          assert_eq(@api.string_field(messages[1], "role"), "tool")
          assert_eq(@api.string_field(messages[1], "toolCallId"), "call_1")
        }
        _ => fail("expected a save-turn action")
      }
    _ => fail("expected a save-turn action")
  }
}

///|
test "an unknown tool is a tool error naming it" {
  match decision_for("tools/call", { "name": "mem_forget" }) {
    Answer(result~, ..) =>
      assert_true(content_text(result).contains("unknown tool: mem_forget"))
    _ => fail("expected an immediate tool error")
  }
}

///|
test "mem://profile reads the profile as a resource, not a tool" {
  match decision_for("resources/read", { "uri": "mem://profile" }) {
    Perform(action~, as_tool~, ..) => {
      assert_false(as_tool)
      assert_true(action is Profile)
    }
    _ => fail("expected a profile read")
  }
}

///|
test "mem://search decodes a percent-encoded query and accepts top_k" {
  match
    decision_for("resources/read", {
      "uri": "mem://search?q=TOML%20%E8%A7%A3%E6%9E%90&top_k=3",
    }) {
    Perform(action~, ..) =>
      match action {
        SearchResource(query~, top_k~) => {
          assert_eq(query, "TOML 解析")
          assert_eq(top_k, 3)
        }
        _ => fail("expected a search action")
      }
    _ => fail("expected a search action")
  }
}

///|
test "a search URI without q is invalid params, not an empty search" {
  match decision_for("resources/read", { "uri": "mem://search?topK=3" }) {
    Fail(code~, ..) => assert_eq(code, CodeInvalidParams)
    _ => fail("expected an invalid-params failure")
  }
}

///|
test "an unknown resource uri is invalid params, with what is supported" {
  match decision_for("resources/read", { "uri": "mem://everything" }) {
    Fail(code~, message~, ..) => {
      assert_eq(code, CodeInvalidParams)
      assert_true(message.contains("unknown resource uri"))
    }
    _ => fail("expected an invalid-params failure")
  }
}

///|
test "percent decoding handles + and multi-byte text" {
  assert_eq(percent_decode("a+b"), "a b")
  assert_eq(percent_decode("%E8%A7%A3"), "解")
  assert_eq(percent_decode("plain"), "plain")
}
