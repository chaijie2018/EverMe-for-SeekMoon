// The install plan, tested where it matters: a merge must never lose somebody
// else's servers or keys, our block must never duplicate, and the paths we write
// into config must be usable from another working directory.

///|
/// The parsed document as a map, for assertions.
fn parse(text : String) -> Map[String, Json] raise {
  let json : Json = @json.parse(text) catch {
    _ => fail("expected JSON: \{text}")
  }
  match json {
    Object(fields) => fields
    _ => fail("expected an object")
  }
}

///|
/// The `mcpServers` map of a document.
fn servers(text : String) -> Map[String, Json] raise {
  match parse(text).get("mcpServers") {
    Some(Object(servers)) => servers
    _ => fail("expected an mcpServers object")
  }
}

///|
test "an explicit --command wins" {
  assert_eq(
    @install.resolve_command("/opt/everme", "/usr/local/bin/everme", "/tmp"),
    "/opt/everme",
  )
}

///|
test "an absolute argv[0] is used as-is" {
  assert_eq(
    @install.resolve_command("", "/usr/local/bin/everme", "/tmp"),
    "/usr/local/bin/everme",
  )
}

///|
test "a relative argv[0] is resolved against the working directory" {
  assert_eq(
    @install.resolve_command("", "_build/native/everme.exe", "/work"),
    "/work/_build/native/everme.exe",
  )
}

///|
test "a bare program name is refused, because PATH may differ later" {
  let outcome = try {
    ignore(@install.resolve_command("", "everme", "/tmp"))
    "accepted"
  } catch {
    @api.ApiError(failure) => failure.kind
    _ => "unexpected error kind"
  }
  assert_eq(outcome, "invalid_args")
}

///|
test "the server entry launches mcp serve" {
  let entry = @install.server_entry("/opt/everme")
  assert_eq(@api.string_field(entry, "command"), "/opt/everme")
  assert_eq(@api.strings_field(entry, "args"), ["mcp", "serve"])
}

///|
test "the skill config names one server and no secrets" {
  let text = @install.skill_config("/opt/everme")
  let table = servers(text)
  assert_eq(table.length(), 1)
  let entry = table[@install.ServerName]
  assert_eq(@api.string_field(entry, "command"), "/opt/everme")
  assert_false(text.contains("evt_"))
  assert_false(text.contains("emk_"))
}

///|
test "the skill document declares itself and shows how to call the server" {
  let text = @install.skill_markdown()
  assert_true(text.has_prefix("---\nname: \{@install.SkillDirName}\n"))
  assert_true(text.contains("description: EverMe personal memory"))
  assert_true(
    text.contains("@mcp.call(\"\{@install.ServerName}\", \"mem_search\""),
  )
  assert_true(
    text.contains("@mcp.call(\"\{@install.ServerName}\", \"mem_save_fact\""),
  )
  assert_true(text.contains("profileUpdated"))
}

///|
test "the skill teaches what to do after a context checkpoint" {
  let text = @install.skill_markdown()
  assert_true(text.contains("## After a context checkpoint"))
  assert_true(text.contains("[context ceiling]"))
  assert_true(text.contains("silence is not evidence"))
  assert_true(text.contains("`git status`"))
  assert_true(text.contains("Never redo a finished step"))
}

///|
test "the skill asks for saves at milestones, not only at the end" {
  let text = @install.skill_markdown()
  assert_true(text.contains("Save at milestones"))
}

///|
test "merging keeps every other key and server" {
  let existing =
    #|{
    #|  "theme": "dark",
    #|  "mcpServers": {
    #|    "other": { "command": "other-bin", "args": ["x"] }
    #|  }
    #|}
  let merged = @install.merge_server(Some(existing), "/opt/everme")
  let document = parse(merged)
  assert_eq(@api.string_field(Json::object(document), "theme"), "dark")
  let table = servers(merged)
  assert_eq(table.length(), 2)
  assert_eq(@api.string_field(table["other"], "command"), "other-bin")
  assert_eq(
    @api.string_field(table[@install.ServerName], "command"),
    "/opt/everme",
  )
}

///|
test "merging replaces our own stale entry" {
  let existing =
    #|{"mcpServers":{"everme-memory":{"command":"/old/path","args":["mcp","serve"]}}}
  let merged = @install.merge_server(Some(existing), "/new/path")
  let table = servers(merged)
  assert_eq(table.length(), 1)
  assert_eq(
    @api.string_field(table[@install.ServerName], "command"),
    "/new/path",
  )
}

///|
test "merging twice changes nothing the second time" {
  let once = @install.merge_server(None, "/opt/everme")
  let twice = @install.merge_server(Some(once), "/opt/everme")
  assert_eq(once, twice)
}

///|
test "merging into nothing creates the document" {
  let merged = @install.merge_server(None, "/opt/everme")
  assert_eq(servers(merged).length(), 1)
}

///|
test "a config that is not JSON is refused rather than overwritten" {
  let outcome = try {
    ignore(@install.merge_server(Some("not json"), "/opt/everme"))
    "accepted"
  } catch {
    @api.ApiError(failure) => failure.kind
    _ => "unexpected error kind"
  }
  assert_eq(outcome, "invalid_args")
}

///|
test "a config whose mcpServers is not an object is refused" {
  let outcome = try {
    ignore(@install.merge_server(Some("{\"mcpServers\": []}"), "/opt/everme"))
    "accepted"
  } catch {
    @api.ApiError(failure) => failure.kind
    _ => "unexpected error kind"
  }
  assert_eq(outcome, "invalid_args")
}

///|
test "removing takes only our entry" {
  let existing =
    #|{"mcpServers":{"everme-memory":{"command":"/opt/everme"},"other":{"command":"x"}}}
  let remaining = @install.remove_server(existing)
  guard remaining is Some(remaining) else { fail("expected a change") }
  let table = servers(remaining)
  assert_eq(table.length(), 1)
  assert_true(table.contains("other"))
}

///|
test "removing when we are absent reports no change" {
  let existing =
    #|{"mcpServers":{"other":{"command":"x"}}}
  assert_true(@install.remove_server(existing) is None)
}

///|
test "the agents block is appended to existing text, which is kept" {
  let updated = @install.upsert_agents_block(
    "# Project\n\nBe brief.\n",
    @install.agents_block(),
  )
  assert_true(updated.has_prefix("# Project\n\nBe brief.\n"))
  assert_true(@install.has_agents_block(updated))
}

///|
test "the agents block goes into an empty file on its own" {
  let updated = @install.upsert_agents_block("", @install.agents_block())
  assert_true(updated.has_prefix("<!-- everme:begin"))
  assert_true(@install.has_agents_block(updated))
}

///|
test "upserting the block twice changes nothing the second time" {
  let once = @install.upsert_agents_block(
    "# Project\n",
    @install.agents_block(),
  )
  let twice = @install.upsert_agents_block(once, @install.agents_block())
  assert_eq(once, twice)
}

///|
test "removing the block keeps the user's own text" {
  let once = @install.upsert_agents_block(
    "# Project\n\nBe brief.\n",
    @install.agents_block(),
  )
  let remaining = @install.remove_agents_block(once)
  guard remaining is Some(remaining) else { fail("expected a change") }
  assert_eq(remaining, "# Project\n\nBe brief.")
  assert_false(@install.has_agents_block(remaining))
}

///|
test "removing a block that is not there reports no change" {
  assert_true(@install.remove_agents_block("# Project\n") is None)
}

///|
test "the rendered config parses back to the same document" {
  let document : Json = {
    "a": 1,
    "b": Json::array([Json("x"), Json::null()]),
    "c": { "d": true },
  }
  let rendered = @install.render_document(document)
  assert_true(rendered.contains("\n  \"a\": 1"))
  assert_eq(@json.parse(rendered).stringify(), document.stringify())
}

///|
async test "copying the binary writes an executable copy outside _build" {
  let dir = @fs.tmpdir(prefix="everme-copy-")
  defer @async.protect_from_cancel(() => purge(dir))
  let source = dir + "/source.bin"
  @fs.write_text(source, "#!/bin/sh\necho hi\n")
  let target = @install.copy_binary(source, dir + "/bin")
  assert_eq(target, dir + "/bin/everme")
  assert_true(@fs.exists(target) catch { _ => false })
  assert_eq(@fs.read_text(target) catch { _ => "" }, "#!/bin/sh\necho hi\n")
  assert_true(@fs.can_execute(target) catch { _ => false })
}

///|
/// Delete `dir` and everything under it, for test cleanup.
async fn purge(dir : String) -> Unit {
  let entries = @fs.readdir(dir) catch { _ => return }
  for entry in entries {
    let path = dir + "/" + entry
    let kind = @fs.kind(path) catch { _ => Unknown }
    if kind is Directory {
      purge(path)
    }
    @fs.remove(path) catch {
      _ => ()
    }
  }
  @fs.remove(dir) catch {
    _ => ()
  }
}
