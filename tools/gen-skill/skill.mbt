// Pure rendering and marketplace validation for `tools/gen-skill`.
//
// Keeping the text here means the interesting behaviour — a config that names no
// machine, a coordinate pinned to the module version, a description that passes
// the marketplace — is testable without touching the filesystem.

///|
/// The MCP server name. Stable on purpose: a skill, this CLI, and any docs must
/// agree on it, and a rename would silently disconnect every installed host.
const ServerName : String = "everme-seekmoon"

///|
/// The skill directory (and the skill's own name).
const SkillDirName : String = "everme-seekmoon"

///|
/// The file a host reads inside the skill directory.
const SkillFileName : String = "SKILL.md"

///|
/// The skill's own MCP config, which SeekMoon loads because it sits beside
/// `SKILL.md`.
const SkillConfigFileName : String = "mcp.json"

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
/// The `mcpServers` entry: how a host starts this server.
///
/// The command is `moonx`, which resolves the package from the registry and runs
/// it under moonrun. No absolute path, so the entry survives a rebuild, a moved
/// checkout, or being copied to another machine.
fn server_entry() -> Json {
  {
    "command": Json("moonx"),
    "args": Json::array([Json(coordinate()), Json("mcp"), Json("serve")]),
  }
}

///|
/// The skill's own `mcp.json`: one server, no secrets (the server reads its
/// credential store itself, so this file can be read and shared).
fn skill_config() -> String {
  let servers : Map[String, Json] = Map([(ServerName, server_entry())])
  let document : Json = { "mcpServers": Json::object(servers) }
  document.stringify()
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

///|
/// The `README.md` a published skill directory ships: what it is, how to run it,
/// and what `auth login` writes once it runs.
fn skill_readme() -> String {
  let text =
    $|# EverMe memory for SeekMoon
    $|
    $|An agent skill: EverMe personal memory (one pool shared across devices and
    $|agents) for [SeekMoon](https://github.com/moonbitlang/openseek).
    $|
    $|`SKILL.md` is the instructions. `mcp.json` registers the `\{ServerName}` MCP
    $|server with the host, addressed by command name — this directory carries no
    $|machine-specific path, so it works anywhere the CLI is installed.
    $|
    $|## What runs
    $|
    $|The server is a MoonBit package: `mcp.json` launches it through `moonx`,
    $|which ships with the toolchain and resolves the pinned version on first use.
    $|
    $|```bash
    $|moonx \{coordinate()} auth login     # or: … auth adopt-evercli
    $|```
    $|
    $|`auth login` registers this machine's agent and stores a `0600` credential;
    $|nothing else is touched. To install the skill itself, unpack this directory
    $|into a skills library (`~/.openseek/skills/`, a workspace's
    $|`.openseek/skills/`, or any `--skills-dir`); `moonx \{coordinate()} doctor`
    $|says what is still missing.
    $|
    $|Source and issues: <https://github.com/chaijie2018/EverMe-for-SeekMoon>
    $|
    $|Licensed under Apache-2.0.
  text
}

///|
/// Whether `name` satisfies the marketplace's rule: 1–64 characters of lowercase
/// letters, digits and single hyphens, with no leading, trailing or doubled one.
fn valid_skill_name(name : String) -> Bool {
  let n = name.length()
  if n < 1 || n > 64 {
    return false
  }
  let mut prev_hyphen = false
  let mut i = 0
  while i < n {
    match name.get_char(i) {
      Some(c) => {
        let allowed = (c >= 'a' && c <= 'z') ||
          (c >= '0' && c <= '9') ||
          c == '-'
        if !allowed {
          return false
        }
        if c == '-' && (i == 0 || prev_hyphen) {
          return false
        }
        prev_hyphen = c == '-'
      }
      None => return false
    }
    i += 1
  }
  !prev_hyphen
}

///|
/// The value of the `description:` line in the rendered skill's frontmatter.
fn description_of(skill : String) -> String? {
  for line in skill.split("\n") {
    let line = line.to_owned()
    if line.has_prefix("description:") {
      return Some(line[12:].trim().to_owned())
    }
  }
  None
}

///|
/// What the marketplace's own validation would reject. Checked before writing a
/// directory because a published version is immutable: a bad upload burns the
/// version number, and the name and description are validated on the server.
fn publish_problems(skill : String) -> Array[String] {
  let problems : Array[String] = []
  if !valid_skill_name(SkillDirName) {
    problems.push(
      "name \"\{SkillDirName}\" must be 1-64 lowercase letters, digits and single hyphens",
    )
  }
  match description_of(skill) {
    Some(text) =>
      if text.is_blank() {
        problems.push("description is empty")
      } else if text.length() > 1024 {
        problems.push(
          "description is \{text.length()} characters; the limit is 1024",
        )
      }
    None => problems.push("SKILL.md has no description line in its frontmatter")
  }
  if skill.length() > 262_144 {
    problems.push("SKILL.md is \{skill.length()} bytes; the limit is 256 KiB")
  }
  problems
}
