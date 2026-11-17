// `everme` — the EverMe CLI for SeekMoon. argparse owns the command tree; each
// command returns the process status and raises `@api.ApiError` for anything a
// user can act on, which `dispatch` renders as text or as the error envelope.

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
