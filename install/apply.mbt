// Writing what `plan` decided: the filesystem half of install and uninstall.
//
// Every write is deliberate about the user's files: a config that already exists
// is backed up once (`<path>.bak`) before our entry is merged, an `AGENTS.md` is
// only touched between our markers, and removal deletes only what this CLI writes.

///|
/// Where to install, and how.
pub(all) struct InstallOptions {
  /// `~/.openseek/skills` unless overridden.
  skills_dir : String
  /// `~/.openseek/mcp.json` unless overridden.
  mcp_config : String
  /// `skill`, `mcp-json`, or `both`.
  mode : String
  /// The `AGENTS.md` to add a marked block to; "" when not requested.
  agents_md : String
  /// Absolute path of the binary `mcp.json` should launch.
  command : String
  /// Compute everything, write nothing.
  dry_run : Bool
}

///|
/// What happened (or, under `--dry-run`, what would have).
pub(all) struct InstallReport {
  skill_dir : String
  skill_written : Bool
  mcp_config : String
  mcp_written : Bool
  backup : String
  agents_md : String
  agents_md_written : Bool
  agents_md_created : Bool
  notes : Array[String]
}

///|
/// What an uninstall removed.
pub(all) struct UninstallReport {
  skill_dir : String
  skill_removed : Bool
  mcp_config : String
  mcp_entry_removed : Bool
  agents_md : String
  agents_md_block_removed : Bool
  agents_md_deleted : Bool
  notes : Array[String]
}

///|
/// Reject a mode we cannot honour, so a typo fails before anything is written.
pub fn check_mode(mode : String) -> Unit raise {
  match mode {
    "skill" | "mcp-json" | "both" => ()
    other =>
      raise @api.ApiError({
        kind: "invalid_args",
        message: "invalid --mode \{other}: use skill, mcp-json, or both",
        hint: "",
        http_status: 0,
        code: 0,
        request_id: "",
      })
  }
}

///|
/// Whether `mode` writes the skill bundle.
pub fn wants_skill(mode : String) -> Bool {
  mode == "skill" || mode == "both"
}

///|
/// Whether `mode` merges the user's MCP config.
pub fn wants_mcp_config(mode : String) -> Bool {
  mode == "mcp-json" || mode == "both"
}

///|
/// Read `path`, or `None` when it does not exist.
async fn read_if_exists(path : String) -> String? {
  if !(@fs.exists(path) catch { _ => false }) {
    return None
  }
  Some(@fs.read_text(path) catch { _ => "" })
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
/// Keep one copy of the pre-install config at `<path>.bak`.
async fn backup(path : String) -> String {
  let text = @fs.read_text(path) catch {
    error =>
      raise @api.ApiError({
        kind: "io",
        message: "cannot read \{path} to back it up: \{error}",
        hint: "",
        http_status: 0,
        code: 0,
        request_id: "",
      })
  }
  let target = path + ".bak"
  write_text(target, text)
  target
}

///|
/// Delete `path` and everything under it; a missing path is fine.
async fn remove_tree(path : String) -> Unit {
  if !(@fs.exists(path) catch { _ => false }) {
    return
  }
  let entries = @fs.readdir(path) catch { _ => [] }
  for entry in entries {
    let child = path + "/" + entry
    let kind = @fs.kind(child) catch { _ => Unknown }
    if kind is Directory {
      remove_tree(child)
    }
    @fs.remove(child) catch {
      _ => ()
    }
  }
  @fs.remove(path) catch {
    _ => ()
  }
}

///|
/// Install the SeekMoon integration: the skill bundle, the shared config, or
/// both, plus an optional `AGENTS.md` block.
pub async fn install(options : InstallOptions) -> InstallReport {
  check_mode(options.mode)
  let notes : Array[String] = []
  if options.dry_run {
    notes.push("--dry-run: nothing was written")
  }
  let skill_dir = options.skills_dir + "/" + SkillDirName
  let mut skill_written = false
  if wants_skill(options.mode) {
    if options.dry_run {
      notes.push(
        "would write \{skill_dir}/\{SkillFileName} and \{SkillConfigFileName}",
      )
    } else {
      if !(@fs.exists(skill_dir) catch { _ => false }) {
        @fs.mkdir(skill_dir, recursive=true) catch {
          error =>
            raise @api.ApiError({
              kind: "io",
              message: "cannot create \{skill_dir}: \{error}",
              hint: "",
              http_status: 0,
              code: 0,
              request_id: "",
            })
        }
      }
      write_text(skill_dir + "/" + SkillFileName, skill_markdown())
      write_text(
        skill_dir + "/" + SkillConfigFileName,
        skill_config(options.command),
      )
      skill_written = true
    }
  }
  let mut backup_path = ""
  let mut mcp_written = false
  if wants_mcp_config(options.mode) {
    let existing = read_if_exists(options.mcp_config)
    let merged = merge_server(existing, options.command)
    if options.dry_run {
      notes.push("would merge \{ServerName} into \{options.mcp_config}")
    } else {
      if existing is Some(_) {
        backup_path = backup(options.mcp_config)
        notes.push("previous config saved to \{backup_path}")
      }
      write_text(options.mcp_config, merged)
      mcp_written = true
    }
  }
  let mut agents_md_written = false
  let mut agents_md_created = false
  if !options.agents_md.is_empty() {
    let existing = read_if_exists(options.agents_md)
    let updated = match existing {
      Some(text) => upsert_agents_block(text, agents_block())
      None => {
        agents_md_created = true
        agents_block() + "\n"
      }
    }
    if options.dry_run {
      notes.push("would write \{options.agents_md}")
    } else {
      write_text(options.agents_md, updated)
      agents_md_written = true
    }
  }
  {
    skill_dir,
    skill_written,
    mcp_config: options.mcp_config,
    mcp_written,
    backup: backup_path,
    agents_md: options.agents_md,
    agents_md_written,
    agents_md_created,
    notes,
  }
}

///|
/// Remove what `install` wrote, and nothing else.
pub async fn uninstall(options : InstallOptions) -> UninstallReport {
  check_mode(options.mode)
  let notes : Array[String] = []
  let skill_dir = options.skills_dir + "/" + SkillDirName
  let had_skill = @fs.exists(skill_dir) catch { _ => false }
  if wants_skill(options.mode) && had_skill {
    if options.dry_run {
      notes.push("would delete \{skill_dir}")
    } else {
      remove_tree(skill_dir)
    }
  }
  let mut entry_removed = false
  if wants_mcp_config(options.mode) {
    match read_if_exists(options.mcp_config) {
      Some(text) => {
        let updated : String? = remove_server(text) catch { _ => None }
        match updated {
          Some(updated) =>
            if options.dry_run {
              notes.push(
                "would remove \{ServerName} from \{options.mcp_config}",
              )
            } else {
              write_text(options.mcp_config, updated)
              entry_removed = true
            }
          None => notes.push("\{ServerName} was not in \{options.mcp_config}")
        }
      }
      None => notes.push("\{options.mcp_config} does not exist")
    }
  }
  let mut block_removed = false
  let mut file_deleted = false
  if !options.agents_md.is_empty() {
    match read_if_exists(options.agents_md) {
      Some(text) => {
        let remaining = remove_agents_block(text)
        match remaining {
          Some(remaining) =>
            if options.dry_run {
              notes.push(
                "would remove the everme block from \{options.agents_md}",
              )
            } else if remaining.is_empty() {
              // The file held nothing but our block: it was ours to remove.
              @fs.remove(options.agents_md) catch {
                _ => ()
              }
              file_deleted = true
              block_removed = true
            } else {
              write_text(options.agents_md, remaining + "\n")
              block_removed = true
            }
          None => notes.push("no everme block in \{options.agents_md}")
        }
      }
      None => notes.push("\{options.agents_md} does not exist")
    }
  }
  {
    skill_dir,
    skill_removed: wants_skill(options.mode) && had_skill,
    mcp_config: options.mcp_config,
    mcp_entry_removed: entry_removed,
    agents_md: options.agents_md,
    agents_md_block_removed: block_removed,
    agents_md_deleted: file_deleted,
    notes,
  }
}
