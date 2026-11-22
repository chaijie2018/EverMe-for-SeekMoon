// Whitebox tests for `tools/gen-skill`: a pinned coordinate, placeholder
// rendering, and template-to-docs sync.

///|
test "the placeholders carry the server and skill names" {
  assert_eq(
    render_skill("a {{server}} b {{skill}}"),
    "a \{ServerName} b \{SkillDirName}",
  )
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
  assert_false(coordinate().contains("/Users/"))
}

///|
async test "the rendered template is exactly the committed docs/SKILL.md" {
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
