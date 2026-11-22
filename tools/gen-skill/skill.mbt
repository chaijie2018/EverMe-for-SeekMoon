// Pure rendering for `tools/gen-skill`.
//
// Keeping the text here means the interesting behaviour — a coordinate pinned to
// the module version, a server name every caller agrees on — is testable without
// touching the filesystem.

///|
/// The MCP server name. Stable on purpose: a skill, this CLI, and any docs must
/// agree on it, and a rename would silently disconnect every installed host.
const ServerName : String = "everme-seekmoon"

///|
/// The skill directory (and the skill's own name).
const SkillDirName : String = "everme-seekmoon"

///|
/// The module this server ships in — the first half of every `moonx` coordinate.
const ModuleName : String = "chaijie2018/EverMe-for-SeekMoon"

///|
/// The package that carries the CLI and the MCP server.
const PackagePath : String = "cmd/everme-seekmoon"

///|
/// The `moonx` coordinate SeekMoon launches. The version is pinned: a published
/// skill is reproducible, and a later release cannot silently change what runs.
fn coordinate() -> String {
  ModuleName + "/" + PackagePath + "@" + @config.Version
}

///|
/// Fill the placeholders the skill template carries: the server name in the
/// frontmatter description and in every `@mcp.call`, the `moonx` coordinate a
/// reader runs, and the skill's own name. Rendering instead of baking keeps a
/// rename and a version bump one constant away.
fn render_skill(template : String) -> String {
  substitute(
    substitute(
      substitute(template, "{{server}}", ServerName),
      "{{coordinate}}",
      coordinate(),
    ),
    "{{skill}}",
    SkillDirName,
  )
}

///|
/// Replace every `from` with `to`. A scan, not a regex: the patterns are
/// literal braces, which a regex would have to escape.
fn substitute(text : String, from : String, to : String) -> String {
  let out = StringBuilder()
  let mut rest : StringView = text
  while true {
    match rest.find(from) {
      Some(at) => {
        out.write_string(rest[:at].to_owned())
        out.write_string(to)
        rest = rest[at + from.length():]
      }
      None => {
        out.write_string(rest.to_owned())
        break
      }
    }
  }
  out.to_string()
}
