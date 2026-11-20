// `everme-seekmoon install` / `everme-seekmoon uninstall` — wire this CLI into SeekMoon.
//
// Three things make it "installed": the account and an agent of our own (so the
// memory endpoints answer), a skill bundle (so the model knows when and how to
// call the tools), and optionally the shared config and a workspace hint. Each is
// reported, because an install that silently changes something is how trust in a
// CLI dies.

///|
/// `$HOME/.openseek/skills` — where SeekMoon reads user-level skills.
fn default_skills_dir() -> String raise {
  @config.home() + "/.openseek/skills"
}

///|
/// `$HOME/.openseek/mcp.json` — the user-level MCP config the desktop reads.
fn default_mcp_config() -> String raise {
  @config.home() + "/.openseek/mcp.json"
}

///|
/// The `AGENTS.md` to touch, or "" when `--agents-md` was not passed.
fn agents_md_path(selected : @argparse.Matches) -> String {
  if !flag_of(selected, "agents-md") {
    return ""
  }
  let workspace = value_of(selected, "workspace")
  let workspace = if workspace.is_empty() {
    @env.current_dir().unwrap_or(".")
  } else {
    workspace
  }
  workspace + "/AGENTS.md"
}

///|
/// The binary path `mcp.json` will launch.
fn command_path(selected : @argparse.Matches) -> String raise {
  let argv0 = match @env.args() {
    [program, ..] => program
    _ => ""
  }
  let cwd = @env.current_dir().unwrap_or(".")
  @install.resolve_command(value_of(selected, "command"), argv0, cwd)
}

///|
/// Make sure this machine has an agent of this CLI's own, registering one when
/// the credential has none. Returns the agent id ("" for a dry run that skipped
/// registration).
async fn ensure_agent(
  base : String,
  platform : String,
  dry_run : Bool,
) -> (String, Bool) {
  let paths = @config.Paths::resolve()
  let creds = @creds.Credentials::load(paths.credentials_file())
  if !creds.has_api_key() {
    not_logged_in(
      "no API key stored, so no agent can be registered", "run `everme-seekmoon auth login`, or `everme-seekmoon auth adopt-evercli` to reuse an evercli login",
    )
  }
  if creds.has_agent_token() {
    return (creds.agent_id, false)
  }
  if dry_run {
    return ("", false)
  }
  let client = @api.Client::new(base~).with_token(creds.api_key)
  let fingerprint = @creds.machine_id(paths.machine_file())
  let (_, agent) = register_agent(client, fingerprint, platform, "SeekMoon")
  creds.agent_id = agent.agent_id
  creds.agent_token = agent.agent_token
  creds.platform = agent.platform
  creds.token_prefix = agent.token_prefix
  creds.save(paths.credentials_file())
  (agent.agent_id, true)
}

///|
/// `everme-seekmoon install`.
async fn install_command(selected : @argparse.Matches) -> Int32 {
  let machine = machine_of(selected)
  let settings = @config.Settings::resolve()
  let base = base_of(selected, settings)
  let platform = platform_of(selected, settings)
  let dry_run = flag_of(selected, "dry-run")
  let mode = match value_of(selected, "mode") {
    "" => "skill"
    mode => mode
  }
  @install.check_mode(mode)
  let (agent_id, registered) = ensure_agent(base, platform, dry_run)
  let skills_dir = match value_of(selected, "skills-dir") {
    "" => default_skills_dir()
    dir => dir
  }
  let mcp_config = match value_of(selected, "mcp-config") {
    "" => default_mcp_config()
    path => path
  }
  let mut command = command_path(selected)
  let copy_to = value_of(selected, "copy-to")
  let mut copied = ""
  if !copy_to.is_empty() {
    if dry_run {
      copied = copy_to + "/everme-seekmoon"
      command = copied
    } else {
      copied = @install.copy_binary(command, copy_to)
      command = copied
    }
  }
  let report = @install.install({
    skills_dir,
    mcp_config,
    mode,
    agents_md: agents_md_path(selected),
    command,
    dry_run,
  })
  let text = StringBuilder()
  text.write_string("everme-seekmoon install\n")
  text.write_string("  command  \{command}\n")
  if !copied.is_empty() {
    text.write_string(
      "  copy     \{if dry_run { "would copy to" } else { "copied to" }} \{copied}\n",
    )
  }
  text.write_string(
    "  agent    \{if agent_id.is_empty() { "none yet" } else { agent_id }}\{if registered { "  (registered now)" } else if agent_id.is_empty() { "" } else { "  (already stored)" }}\n",
  )
  if @install.wants_skill(mode) {
    text.write_string(
      "  skill    \{report.skill_dir}  (\{if dry_run { "would write" } else if report.skill_written { "written" } else { "not written" }})\n",
    )
  }
  if @install.wants_mcp_config(mode) {
    text.write_string(
      "  config   \{report.mcp_config}  (\{if dry_run { "would merge" } else if report.mcp_written { "merged" } else { "not written" }})\n",
    )
  }
  if !report.agents_md.is_empty() {
    let state = if dry_run {
      if report.agents_md_created {
        "would be created"
      } else {
        "would get the block"
      }
    } else if report.agents_md_created {
      "created"
    } else if report.agents_md_written {
      "block updated"
    } else {
      "not written"
    }
    text.write_string("  agents   \{report.agents_md}  (\{state})\n")
  }
  for note in report.notes {
    text.write_string("  note     \{note}\n")
  }
  // A path inside `_build` is a build artifact: `moon clean`, a rebuild, or a
  // moved checkout takes the server with it, and the host would only notice as a
  // failed connection. Say so at install time.
  if command.contains("/_build/") {
    text.write_string(
      "  note     this path is a build artifact; pass --copy-to ~/.local/bin to keep a stable copy out of _build\n",
    )
  }
  if !dry_run && report.skill_written {
    text.write_string(
      "\nNext: reopen the workspace in SeekMoon (or start a new session) so the skill is loaded, then ask `what do you remember about me?`\n",
    )
  }
  let data : Json = {
    "command": Json(command),
    "mode": Json(mode),
    "agentId": Json(agent_id),
    "registered": Json(registered),
    "skillDir": Json(report.skill_dir),
    "skillWritten": Json(report.skill_written),
    "mcpConfig": Json(report.mcp_config),
    "mcpWritten": Json(report.mcp_written),
    "copiedTo": Json(copied),
    "backup": Json(report.backup),
    "agentsMd": Json(report.agents_md),
    "agentsMdWritten": Json(report.agents_md_written),
    "agentsMdCreated": Json(report.agents_md_created),
    "dryRun": Json(dry_run),
    "notes": Json(report.notes),
  }
  emit(machine, text.to_string(), data)
  0
}

///|
/// `everme-seekmoon uninstall`.
async fn uninstall_command(selected : @argparse.Matches) -> Int32 {
  let machine = machine_of(selected)
  let dry_run = flag_of(selected, "dry-run")
  let mode = match value_of(selected, "mode") {
    "" => "skill"
    mode => mode
  }
  @install.check_mode(mode)
  let skills_dir = match value_of(selected, "skills-dir") {
    "" => default_skills_dir()
    dir => dir
  }
  let mcp_config = match value_of(selected, "mcp-config") {
    "" => default_mcp_config()
    path => path
  }
  let report = @install.uninstall({
    skills_dir,
    mcp_config,
    mode,
    agents_md: agents_md_path(selected),
    command: "",
    dry_run,
  })
  let text = StringBuilder()
  text.write_string("everme-seekmoon uninstall\n")
  if @install.wants_skill(mode) {
    text.write_string(
      "  skill    \{report.skill_dir}  (\{if report.skill_removed { "deleted" } else { "not installed" }}" +
      "\{if dry_run && report.skill_removed { "" } else { "" }})\n",
    )
  }
  if @install.wants_mcp_config(mode) {
    text.write_string(
      "  config   \{report.mcp_config}  (\{if report.mcp_entry_removed { "entry removed" } else { "nothing of ours" }})\n",
    )
  }
  if !report.agents_md.is_empty() {
    text.write_string(
      "  agents   \{report.agents_md}  (\{if report.agents_md_deleted { "block removed; the file was ours, so it is gone" } else if report.agents_md_block_removed { "block removed" } else { "nothing of ours" }})\n",
    )
  }
  for note in report.notes {
    text.write_string("  note     \{note}\n")
  }
  let data : Json = {
    "mode": Json(mode),
    "skillDir": Json(report.skill_dir),
    "skillRemoved": Json(report.skill_removed),
    "mcpConfig": Json(report.mcp_config),
    "mcpEntryRemoved": Json(report.mcp_entry_removed),
    "agentsMd": Json(report.agents_md),
    "agentsMdBlockRemoved": Json(report.agents_md_block_removed),
    "agentsMdDeleted": Json(report.agents_md_deleted),
    "dryRun": Json(dry_run),
    "notes": Json(report.notes),
  }
  emit(machine, text.to_string(), data)
  0
}
