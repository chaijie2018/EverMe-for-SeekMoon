// `moon run tools/gen-skill` — render `docs/SKILL.template.md`:
//
//   moon run tools/gen-skill                      refresh `docs/SKILL.md`
//   moon run tools/gen-skill -- --check           fail if `docs/SKILL.md` is stale or invalid
//   moon run tools/gen-skill -- --out <dir>       write the publishable skill directory

///|
fn root_command() -> @argparse.Command {
  Command(
    "gen-skill",
    about="Render `docs/SKILL.template.md` into `docs/SKILL.md` or a publishable skill directory.",
    options=[
      @argparse.OptionArg(
        "out",
        long="out",
        default_values=[""],
        about="Write the publishable skill directory (SKILL.md, mcp.json, README.md) here instead of only refreshing docs/SKILL.md.",
      ),
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
        about="Fail if docs/SKILL.md is stale or the rendered skill violates marketplace rules.",
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
  let out = value_of(matches, "out")
  let check = flag_of(matches, "check")
  let dry_run = flag_of(matches, "dry-run")
  if check && !out.is_empty() {
    raise @api.ApiError({
      kind: "invalid_args",
      message: "--check and --out cannot be used together",
      hint: "run --check alone to verify docs/SKILL.md, or --out <dir> to write a skill directory",
      http_status: 0,
      code: 0,
      request_id: "",
    })
  }
  let root = module_root(@env.current_dir().unwrap_or("."))
  let rendered = render_from_checkout(root)
  if !out.is_empty() {
    let report = write_skill_dir(out, rendered, dry_run)
    let text = StringBuilder()
    text.write_string("gen-skill\n")
    text.write_string(
      "  out      \{report.dir}  (\{if dry_run { "would write" } else if report.written { "written" } else { "not written" }})\n",
    )
    for name in report.files {
      text.write_string("  file     \{name}\n")
    }
    for note in report.notes {
      text.write_string("  note     \{note}\n")
    }
    if !dry_run && report.written {
      text.write_string(
        "\nNext: `moon install moonbit-community/skills`, then `skills publish \{report.dir} --version <x.y.z>` — the version is immutable once published.\n",
      )
    }
    let data : Json = {
      "dir": Json(report.dir),
      "files": Json::array(report.files.map(name => Json(name))),
      "written": Json(report.written),
      "dryRun": Json(dry_run),
    }
    if machine {
      println(@cli.ok_envelope(data).stringify())
    } else {
      println(text.to_string())
    }
    return 0
  }
  let rendered_path = root + "/" + RenderedDoc
  let committed = @fs.read_text(rendered_path) catch { _ => "" }
  let problems = publish_problems(rendered)
  if check {
    if !problems.is_empty() {
      raise @api.ApiError({
        kind: "invalid_skill",
        message: "rendered skill violates marketplace rules: \{problems.join("; ")}",
        hint: "fix \{TemplateSource}",
        http_status: 0,
        code: 0,
        request_id: "",
      })
    }
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
