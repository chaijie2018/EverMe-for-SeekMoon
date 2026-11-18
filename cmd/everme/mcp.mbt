// `everme mcp …` — the stdio server SeekMoon launches, plus a self-check that
// proves the protocol answers and one real backend call without a host.

///|
/// A client presenting this CLI's own agent token. The memory endpoints take no
/// agent id — the token is the identity — so a missing `evt_` is a local problem
/// with a local fix, not something to discover mid-session.
async fn memory_client(selected : @argparse.Matches) -> @api.Client {
  let paths = @config.Paths::resolve()
  let settings = @config.Settings::resolve()
  let base = base_of(selected, settings)
  let creds = @creds.Credentials::load(paths.credentials_file())
  if !creds.has_agent_token() {
    not_logged_in(
      "no agent token stored: the memory endpoints need this CLI's own evt_", "run `everme doctor --probe-platform` to register one, then retry",
    )
  }
  @api.Client::new(base~).with_token(creds.agent_token)
}

///|
/// `everme mcp <subcommand>`.
async fn mcp_command(m : @argparse.Matches) -> Int32 {
  guard m.subcommand is Some((name, selected)) else {
    usage("`mcp` needs a subcommand: serve or test")
  }
  match name {
    "serve" => mcp_serve(selected)
    "test" => mcp_test(selected)
    _ => usage("unknown mcp subcommand: \{name}")
  }
}

///|
/// `everme mcp serve` — speak MCP on stdin/stdout until the host closes the pipe.
async fn mcp_serve(selected : @argparse.Matches) -> Int32 {
  let client = memory_client(selected)
  @mcp.serve(client)
  0
}

///|
/// `everme mcp test` — the protocol answers a host would get, then one real
/// `mem_context`, so a bad token or a wrong API base fails here instead of inside
/// a session.
async fn mcp_test(selected : @argparse.Matches) -> Int32 {
  let machine = machine_of(selected)
  let client = memory_client(selected)
  let initialize : Json = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": { "protocolVersion": "2024-11-05" },
  }
  let tools : Json = { "jsonrpc": "2.0", "id": 2, "method": "tools/list" }
  let resources : Json = {
    "jsonrpc": "2.0",
    "id": 3,
    "method": "resources/list",
  }
  let profile_request : Json = {
    "jsonrpc": "2.0",
    "id": 4,
    "method": "resources/read",
    "params": { "uri": "mem://profile" },
  }
  let context = @mcp.Action::Context(force_refresh=false)
  let recalled = match @mcp.execute(context, client) {
    Ok(result) => result
    Err(message) =>
      return fail_with_generic(
        "the backend refused the profile read: \{message}",
      )
  }
  let preview = @mcp.content_text(recalled)
  let names = @mcp.tool_names()
  let text = StringBuilder()
  text.write_string("everme mcp test\n")
  text.write_string(
    "  initialize    → \{@mcp.describe_decision(initialize)}\n",
  )
  text.write_string(
    "  tools/list    → \{@mcp.describe_decision(tools)}  (\{names.join(", ")})\n",
  )
  text.write_string(
    "  resources/list→ \{@mcp.describe_decision(resources)}\n",
  )
  text.write_string(
    "  resources/read→ \{@mcp.describe_decision(profile_request)}\n",
  )
  text.write_string(
    "  mem_context   → \{if preview.is_empty() { "empty" } else { "\{preview.length()} chars" }}\n",
  )
  if !preview.is_empty() {
    text.write_string("\n--- first 400 chars ---\n\{preview[:400]}\n")
  }
  let data : Json = {
    "tools": Json(names),
    "contextChars": Json(preview.length()),
    "contextPreview": Json(preview[:400].to_owned()),
  }
  emit(machine, text.to_string(), data)
  0
}

///|
/// Report a failure in the caller's shape, classified as a local IO problem.
fn[T] fail_with_generic(message : String) -> T raise {
  raise @api.ApiError({
    kind: "io",
    message,
    hint: "",
    http_status: 0,
    code: 0,
    request_id: "",
  })
}
