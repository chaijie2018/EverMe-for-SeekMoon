// Filesystem half of `tools/gen-skill`: locate the module checkout, read
// `docs/SKILL.template.md`, refresh `docs/SKILL.md`, and write a publishable
// skill directory (`SKILL.md`, `mcp.json`, `README.md`).

///|
/// The rendered document, relative to the module root.
const RenderedDoc : String = "docs/SKILL.md"

///|
/// The template, relative to the module root.
const TemplateSource : String = "docs/SKILL.template.md"

///|
struct WriteReport {
  dir : String
  files : Array[String]
  written : Bool
  notes : Array[String]
}

///|
fn parent_of(dir : String) -> String? {
  let mut i = dir.length() - 1
  while i > 0 {
    if dir[i] == '/' {
      return Some(dir[:i].to_owned())
    }
    i -= 1
  }
  None
}

///|
/// The nearest ancestor of `cwd` whose `moon.mod` is this module.
async fn module_root(cwd : String) -> String {
  let mut dir = cwd
  let mut depth = 0
  while depth < 8 && !dir.is_empty() {
    let manifest = dir + "/moon.mod"
    let exists = @fs.exists(manifest) catch { _ => false }
    if exists {
      let text = @fs.read_text(manifest) catch { _ => "" }
      if text.contains("\"" + ModuleName + "\"") {
        return dir
      }
      raise @api.ApiError({
        kind: "invalid_args",
        message: "\{dir}/moon.mod is not \{ModuleName}",
        hint: "run this from the project checkout",
        http_status: 0,
        code: 0,
        request_id: "",
      })
    }
    match parent_of(dir) {
      Some(parent) => {
        dir = parent
        depth += 1
      }
      None => break
    }
  }
  raise @api.ApiError({
    kind: "not_found",
    message: "cannot find \{ModuleName}'s checkout above \{cwd}",
    hint: "run this inside the project checkout",
    http_status: 0,
    code: 0,
    request_id: "",
  })
}

///|
/// Make sure `path`'s parent directory exists.
async fn ensure_parent(path : String) -> Unit {
  let parent = match path.rev_split_once("/") {
    Some((dir, _)) => if dir.is_empty() { "/" } else { dir.to_owned() }
    None => "."
  }
  @fs.mkdir(parent, recursive=true) catch {
    _ => ()
  }
}

///|
/// Write `text`, creating parent directories.
async fn write_text(path : String, text : String) -> Unit {
  ensure_parent(path)
  @fs.write_text(path, text) catch {
    error =>
      raise @api.ApiError({
        kind: "io",
        message: "cannot write \{path}: \{error}",
        hint: "check permissions on that directory",
        http_status: 0,
        code: 0,
        request_id: "",
      })
  }
}

///|
/// Read and render `docs/SKILL.template.md` from `root`.
async fn render_from_checkout(root : String) -> String {
  let path = root + "/" + TemplateSource
  let template = @fs.read_text(path) catch {
    error =>
      raise @api.ApiError({
        kind: "io",
        message: "cannot read \{path}: \{error}",
        hint: "check that \{TemplateSource} exists in this checkout",
        http_status: 0,
        code: 0,
        request_id: "",
      })
  }
  render_skill(template)
}

///|
/// Write the directory a marketplace publish ships: the skill, a config that
/// addresses the server by `moonx` coordinate, and a README.
async fn write_skill_dir(
  dir : String,
  skill : String,
  dry_run : Bool,
) -> WriteReport {
  let notes : Array[String] = []
  let problems = publish_problems(skill)
  if !problems.is_empty() {
    raise @api.ApiError({
      kind: "invalid_skill",
      message: "this skill cannot be published: \{problems.join("; ")}",
      hint: "fix \{TemplateSource}",
      http_status: 0,
      code: 0,
      request_id: "",
    })
  }
  let files = [SkillFileName, SkillConfigFileName, "README.md"]
  if dry_run {
    for name in files {
      notes.push("would write \{dir}/\{name}")
    }
    return { dir, files, written: false, notes }
  }
  write_text(dir + "/" + SkillFileName, skill)
  write_text(dir + "/" + SkillConfigFileName, skill_config())
  write_text(dir + "/README.md", skill_readme())
  { dir, files, written: true, notes }
}
