// `moon run tools/gen-skill` — render `docs/SKILL.template.md`:
//
//   moon run tools/gen-skill                      refresh `docs/SKILL.md`
//   moon run tools/gen-skill -- --check           fail if `docs/SKILL.md` is stale

///|
fn root_command() -> @argparse.Command {
  Command(
    "gen-skill",
    about="Render `docs/SKILL.template.md` into `docs/SKILL.md`.",
    options=[
      @argparse.OptionArg(
        "format",
        long="format",
        default_values=["text"],
        about="Output format: text or json.",
      ),
    ],
    flags=[
      @argparse.FlagArg(
        "check",
        long="check",
        about="Fail if docs/SKILL.md is stale.",
      ),
      @argparse.FlagArg(
        "dry-run",
        long="dry-run",
        about="Report what would be written; write nothing.",
      ),
    ],
  )
}

///|
fn value_of(m : @argparse.Matches, name : String) -> String {
  match m.values.get(name) {
    Some([value, ..]) => value
    _ => ""
  }
}

///|
fn flag_of(m : @argparse.Matches, name : String) -> Bool {
  match m.flags.get(name) {
    Some(value) => value
    None => false
  }
}

///|
async fn write_stderr(text : String) -> Unit {
  @stdio.stderr.text.write(text) catch {
    _ => ()
  }
}

///|
async fn run() -> Int32 {
  let matches = @argparse.parse(root_command(), env=@env.get_env_vars())
  let machine = @cli.machine_format(value_of(matches, "format"))
  let check = flag_of(matches, "check")
  let dry_run = flag_of(matches, "dry-run")
  let root = module_root(@env.current_dir().unwrap_or("."))
  let rendered = render_from_checkout(root)
  let rendered_path = root + "/" + RenderedDoc
  let committed = @fs.read_text(rendered_path) catch { _ => "" }
  if check {
    if committed != rendered {
      raise @api.ApiError({
        kind: "invalid_args",
        message: "\{RenderedDoc} is stale",
        hint: "run `moon run tools/gen-skill` after editing \{TemplateSource}",
        http_status: 0,
        code: 0,
        request_id: "",
      })
    }
    if machine {
      println(
        @cli.ok_envelope({ "doc": Json(RenderedDoc), "upToDate": true }).stringify(),
      )
    } else {
      println("\{RenderedDoc} is up to date")
    }
    return 0
  }
  let changed = committed != rendered
  if changed && !dry_run {
    write_text(rendered_path, rendered)
  }
  let status_line = if !changed {
    "\{RenderedDoc} is already up to date"
  } else if dry_run {
    "would write \{RenderedDoc} (\{rendered.length()} bytes)"
  } else {
    "wrote \{RenderedDoc} (\{rendered.length()} bytes)"
  }
  if machine {
    println(
      @cli.ok_envelope({
        "doc": Json(RenderedDoc),
        "written": Json(changed && !dry_run),
        "dryRun": Json(dry_run),
      }).stringify(),
    )
  } else {
    println(status_line)
  }
  0
}

///|
async fn main {
  let status = run() catch {
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
