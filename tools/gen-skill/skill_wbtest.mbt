// Whitebox tests for `tools/gen-skill`: no machine path, pinned coordinate,
// marketplace validation, clean write/dry-run, and template-to-docs sync.

///|
fn parse_json(text : String) -> Map[String, Json] raise {
  let json : Json = @json.parse(text) catch {
    _ => fail("expected JSON: \{text}")
  }
  match json {
    Object(fields) => fields
    _ => fail("expected an object")
  }
}

///|
fn servers_of(text : String) -> Map[String, Json] raise {
  match parse_json(text).get("mcpServers") {
    Some(Object(servers)) => servers
    _ => fail("expected an mcpServers object")
  }
}

///|
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

///|
test "the server entry launches the package under moonx" {
  let entry = server_entry()
  assert_eq(@api.string_field(entry, "command"), "moonx")
  assert_eq(@api.strings_field(entry, "args"), [coordinate(), "mcp", "serve"])
  assert_false(coordinate().contains("/Users/"))
}

///|
test "the skill config names one server and no secrets" {
  let text = skill_config()
  let table = servers_of(text)
  assert_eq(table.length(), 1)
  let entry = table[ServerName]
  assert_eq(@api.string_field(entry, "command"), "moonx")
  assert_false(text.contains("emk_"))
  assert_false(text.contains("/Users/"))
}

///|
test "the skill config is one server and nothing else" {
  let document : Json = @json.parse(skill_config())
  guard document is Object(root) else { fail("the config is not an object") }
  assert_eq(root.length(), 1)
  guard root.get("mcpServers") is Some(Object(servers_map)) else {
    fail("no mcpServers object")
  }
  assert_eq(servers_map.length(), 1)
  assert_true(servers_map.contains(ServerName))
}

///|
test "the coordinate pins a version" {
  let parts : Array[String] = coordinate()
    .split("@")
    .map(p => p.to_owned())
    .collect()
  assert_eq(parts.length(), 2)
  assert_eq(parts[0], "chaijie2018/EverMe-for-SeekMoon/cmd/everme-seekmoon")
  assert_false(parts[1].is_blank())
}

///|
test "the placeholders carry the server and skill names" {
  assert_eq(
    render_skill("a {{server}} b {{skill}}"),
    "a \{ServerName} b \{SkillDirName}",
  )
}

///|
test "the marketplace name rules" {
  assert_true(valid_skill_name("everme-seekmoon"))
  assert_true(valid_skill_name("a"))
  assert_true(valid_skill_name("a1-b2"))
  assert_false(valid_skill_name(""))
  assert_false(valid_skill_name("-lead"))
  assert_false(valid_skill_name("trail-"))
  assert_false(valid_skill_name("double--hyphen"))
  assert_false(valid_skill_name("Upper"))
  assert_false(valid_skill_name("under_score"))
}

///|
async test "the rendered template is exactly the committed docs/SKILL.md and passes validation" {
  let root = module_root(@env.current_dir().unwrap_or("."))
  let rendered = render_from_checkout(root)
  let committed = @fs.read_text(root + "/docs/SKILL.md")
  assert_eq(rendered, committed)
  assert_true(rendered.has_prefix("---\nname: \{SkillDirName}\n"))
  assert_true(rendered.contains("description: EverMe personal memory"))
  assert_true(rendered.contains("@mcp.call(\"\{ServerName}\", \"mem_search\""))
  assert_true(
    rendered.contains("@mcp.call(\"\{ServerName}\", \"mem_save_fact\""),
  )
  assert_true(rendered.contains("profileUpdated"))
  assert_true(rendered.contains("## After a context checkpoint"))
  assert_true(rendered.contains("[context ceiling]"))
  assert_true(rendered.contains("silence is not evidence"))
  assert_true(rendered.contains("`git status`"))
  assert_true(rendered.contains("Never redo a finished step"))
  assert_true(rendered.contains("Save at milestones"))
  let problems = publish_problems(rendered)
  if problems.length() > 0 {
    fail(problems.join("; "))
  }
}

///|
async test "the pinned coordinate matches moon.mod's version" {
  let root = module_root(@env.current_dir().unwrap_or("."))
  let manifest = @fs.read_text(root + "/moon.mod")
  let mut declared = ""
  for line in manifest.split("\n") {
    let line = line.to_owned()
    if line.has_prefix("version") && line.contains("\"") {
      match line.split_once("\"") {
        Some((_, rest)) =>
          match rest.split_once("\"") {
            Some((value, _)) => declared = value.to_owned()
            None => ()
          }
        None => ()
      }
    }
  }
  assert_eq(@config.Version, declared)
  assert_true(coordinate().has_suffix("@" + declared))
}

///|
async test "gen-skill --out writes SKILL.md, a command-name config, and a README without machine paths" {
  let root = module_root(@env.current_dir().unwrap_or("."))
  let skill = render_from_checkout(root)
  let dir = @fs.tmpdir(prefix="everme-seekmoon-skill-")
  defer @async.protect_from_cancel(() => purge(dir))
  let report = write_skill_dir(dir, skill, false)
  assert_true(report.written)
  assert_eq(report.files.length(), 3)
  let written_skill = @fs.read_text(dir + "/" + SkillFileName) catch {
    _ => ""
  }
  assert_eq(written_skill, skill)
  let config = @fs.read_text(dir + "/" + SkillConfigFileName) catch {
    _ => ""
  }
  assert_true(config.contains("\"command\":\"moonx\""))
  assert_true(config.contains(coordinate()))
  let readme = @fs.read_text(dir + "/README.md") catch { _ => "" }
  assert_true(readme.contains("Apache-2.0"))
  assert_true(readme.contains("moonx"))
  for name in [SkillFileName, SkillConfigFileName, "README.md"] {
    let text = @fs.read_text(dir + "/" + name) catch { _ => "" }
    assert_false(text.contains("/Users/"))
    assert_false(text.contains("/home/"))
    assert_false(text.contains(dir))
  }
}

///|
async test "gen-skill --out --dry-run reports the files and writes nothing" {
  let root = module_root(@env.current_dir().unwrap_or("."))
  let skill = render_from_checkout(root)
  let base = @fs.tmpdir(prefix="everme-seekmoon-skill-")
  defer @async.protect_from_cancel(() => purge(base))
  let dir = base + "/not-written"
  let report = write_skill_dir(dir, skill, true)
  assert_false(report.written)
  assert_eq(report.notes.length(), 3)
  assert_false(@fs.exists(dir) catch { _ => false })
}
