// `everme` — the EverMe CLI for SeekMoon. argparse owns the command tree; each
// command returns the process status and raises `@api.ApiError` for anything a
// user can act on, which `dispatch` renders as text or as the error envelope.

///|
/// Where things get installed: the skills library, the shared config, and the
/// workspace whose `AGENTS.md` may be touched.
fn location_options() -> Array[@argparse.OptionArg] {
  [
    @argparse.OptionArg(
      "skills-dir",
      long="skills-dir",
      default_values=[""],
      about="Skills library to install into (default: $HOME/.openseek/skills).",
    ),
    @argparse.OptionArg(
      "mcp-config",
      long="mcp-config",
      default_values=[""],
      about="User-level MCP config to merge into (default: $HOME/.openseek/mcp.json).",
    ),
    @argparse.OptionArg(
      "workspace",
      long="workspace",
      default_values=[""],
      about="Workspace whose AGENTS.md --agents-md touches (default: the current directory).",
    ),
  ]
}

///|
/// `install`'s options: where, plus the binary path to record.
fn install_options() -> Array[@argparse.OptionArg] {
  [
    @argparse.OptionArg(
      "mode",
      long="mode",
      default_values=["skill"],
      about="Where to install: skill (self-contained, default), mcp-json (the shared config), or both.",
    ),
    ..location_options(),
    @argparse.OptionArg(
      "command",
      long="command",
      default_values=[""],
      about="Path of the binary mcp.json should launch (default: this executable's path).",
    ),
  ]
}

///|
/// `install`'s flags.
fn install_flags() -> Array[@argparse.FlagArg] {
  [
    @argparse.FlagArg(
      "agents-md",
      long="agents-md",
      about="Also add a marked block to the workspace's AGENTS.md (creates it when missing).",
    ),
    @argparse.FlagArg(
      "dry-run",
      long="dry-run",
      about="Report what would change; write nothing and register no agent.",
    ),
  ]
}

///|
/// The options every command accepts: where to talk, whom to be, and how to
/// print. Global so they read the same before or after the subcommand.
fn global_options() -> Array[@argparse.OptionArg] {
  [
    @argparse.OptionArg(
      "format",
      long="format",
      default_values=["text"],
      global=true,
      about="Output format: text or json.",
    ),
    @argparse.OptionArg(
      "platform",
      long="platform",
      default_values=[""],
      global=true,
      about="Platform label to register under upstream (default: seekmoon, or EVERME_PLATFORM).",
    ),
    @argparse.OptionArg(
      "api-base",
      long="api-base",
      default_values=[""],
      global=true,
      about="EverMe API base URL (default: https://api.everme.evermind.ai, or EVERME_API_BASE).",
    ),
  ]
}

///|
/// The command tree. `subcommand_required` keeps a bare `everme` an error:
/// automation should say what it wants.
fn root_command() -> @argparse.Command {
  Command(
    "everme",
    about="EverMe personal memory for SeekMoon.",
    subcommand_required=true,
    disable_help_subcommand=true,
    options=global_options(),
    subcommands=[
      Command("version", about="Print the version."),
      Command(
        "auth",
        about="Log in, inspect, adopt, or drop this machine's EverMe credential.",
        subcommand_required=true,
        disable_help_subcommand=true,
        subcommands=[
          Command(
            "login",
            about="Device-flow login in the terminal (or store an API key).",
            options=[
              @argparse.OptionArg(
                "api-key",
                long="api-key",
                default_values=[""],
                about="Store this emk_ API key instead of running the device flow.",
              ),
              @argparse.OptionArg(
                "device-code",
                long="device-code",
                default_values=[""],
                about="Poll once for a device flow started earlier (resume a --no-wait login).",
              ),
            ],
            flags=[
              @argparse.FlagArg(
                "no-wait",
                long="no-wait",
                about="Start the device flow, print the URL and code, and exit without polling.",
              ),
            ],
          ),
          Command(
            "status",
            about="Show the stored credential (masked) and the cached account.",
          ),
          Command(
            "adopt-evercli",
            about="Reuse an evercli login already present on this machine.",
          ),
          Command("logout", about="Delete the stored credential."),
          Command(
            "disconnect-agent",
            about="Disconnect one of this account's agents, e.g. one registered under a label you no longer want.",
            options=[
              @argparse.OptionArg(
                "agent-id",
                long="agent-id",
                default_values=[""],
                about="Agent id to disconnect; `everme doctor` prints this CLI's own agent id.",
              ),
            ],
          ),
        ],
      ),
      Command(
        "install",
        about="Wire EverMe memory into SeekMoon: register an agent and write the skill bundle.",
        options=install_options(),
        flags=install_flags(),
      ),
      Command(
        "uninstall",
        about="Remove what install wrote, and nothing else.",
        options=[
          @argparse.OptionArg(
            "mode",
            long="mode",
            default_values=["skill"],
            about="What to remove: skill, mcp-json, or both.",
          ),
          ..location_options(),
        ],
        flags=[
          @argparse.FlagArg(
            "agents-md",
            long="agents-md",
            about="Also remove the everme block from the workspace's AGENTS.md.",
          ),
          @argparse.FlagArg(
            "dry-run",
            long="dry-run",
            about="Report what would change; write nothing.",
          ),
        ],
      ),
      Command(
        "import",
        about="Bring existing history into EverMe.",
        subcommand_required=true,
        disable_help_subcommand=true,
        subcommands=[
          Command(
            "sessions",
            about="Import this machine's SeekMoon sessions, incrementally.",
            options=[
              @argparse.OptionArg(
                "store",
                long="store",
                default_values=[""],
                about="Session store to read (default: this workspace's .openseek/sessions, else $HOME/.openseek/sessions).",
              ),
              @argparse.OptionArg(
                "since-days",
                long="since-days",
                default_values=[""],
                about="Only sessions modified within this many days (default: all).",
              ),
              @argparse.OptionArg(
                "limit",
                long="limit",
                default_values=[""],
                about="Import at most this many sessions (default: all).",
              ),
              @argparse.OptionArg(
                "batch",
                long="batch",
                default_values=[""],
                about="Turns per request (default 100; the gateway caps a request at 500).",
              ),
            ],
            flags=[
              @argparse.FlagArg(
                "dry-run",
                long="dry-run",
                about="Report what would be sent; write nothing and reach no backend.",
              ),
            ],
          ),
        ],
      ),
      Command(
        "mcp",
        about="Serve EverMe memory over MCP (stdio), or self-check it.",
        subcommand_required=true,
        disable_help_subcommand=true,
        subcommands=[
          Command(
            "serve",
            about="Speak MCP on stdin/stdout — the command SeekMoon launches.",
          ),
          Command(
            "test",
            about="Self-check: the protocol answers a host would get, plus one real mem_context.",
          ),
        ],
      ),
      Command(
        "doctor",
        about="Check credentials, connectivity, and the platform label.",
        flags=[
          @argparse.FlagArg(
            "probe-platform",
            long="probe-platform",
            about="Ask the backend whether it accepts the platform label: one /agents/list and one /agents call (the latter registers an agent unless --no-register).",
          ),
          @argparse.FlagArg(
            "no-register",
            long="no-register",
            about="With --probe-platform, stop after /agents/list and do not register an agent.",
          ),
        ],
      ),
    ],
  )
}

///|
/// Run `everme`.
async fn main {
  let status = dispatch() catch {
    @api.ApiError(failure) => {
      write_stderr(@cli.render_failure(failure) + "\n")
      @cli.exit_code(failure.kind)
    }
    error => {
      write_stderr("error: \{error}\n")
      1
    }
  }
  @sys.exit(status)
}

///|
/// Parse, run the selected command, and report a command failure in the shape
/// the caller asked for: envelope on stdout for `--format json`, one line plus
/// a hint on stderr otherwise.
async fn dispatch() -> Int32 {
  let matches = @argparse.parse(root_command(), env=@env.get_env_vars())
  guard matches.subcommand is Some((name, selected)) else {
    usage("missing subcommand")
  }
  let machine = machine_of(selected)
  let outcome : Result[Int32, @api.Failure] = Ok(run_command(name, selected)) catch {
    @api.ApiError(failure) => Err(failure)
    error => raise error
  }
  match outcome {
    Ok(status) => status
    Err(failure) =>
      if machine {
        println(@cli.error_envelope(failure).stringify())
        @cli.exit_code(failure.kind)
      } else {
        write_stderr(@cli.render_failure(failure) + "\n")
        @cli.exit_code(failure.kind)
      }
  }
}

///|
/// Dispatch on the selected subcommand.
async fn run_command(name : String, m : @argparse.Matches) -> Int32 {
  match name {
    "version" => command_version(m)
    "auth" => auth_command(m)
    "install" => install_command(m)
    "uninstall" => uninstall_command(m)
    "import" => import_command(m)
    "mcp" => mcp_command(m)
    "doctor" => doctor_command(m)
    _ => usage("unknown subcommand: \{name}")
  }
}

///|
/// `everme version`.
fn command_version(m : @argparse.Matches) -> Int32 raise {
  let machine = machine_of(m)
  let settings = @config.Settings::resolve()
  if machine {
    emit(true, "", {
      "name": "everme",
      "version": Json(@config.Version),
      "platform": Json(settings.platform),
    })
  } else {
    println("everme \{@config.Version} (EverMe personal memory for SeekMoon)")
  }
  0
}
