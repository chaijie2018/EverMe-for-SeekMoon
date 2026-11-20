// `everme-seekmoon doctor` — the honest self-check. Two of its checks are local
// (credential present, account reachable); `--probe-platform` adds the two
// that answer the question this CLI cannot answer from source code: does this
// EverMe backend accept the platform label we want to register under?
//
// The probe is deliberately shaped like `install` (list first, register only
// when this machine has no agent yet) so running it twice does not pile up
// agents, and a successful registration stores the token it minted.

///|
/// One line of the report. `state` is `ok`, `fail`, or `skip`.
struct Check {
  label : String
  state : String
  http_status : Int32
  status : Int32
  detail : String
  error : String
  request_id : String
}

///|
/// A check that passed.
fn Check::ok(
  label : String,
  http_status : Int32,
  status : Int32,
  detail : String,
) -> Check {
  {
    label,
    state: "ok",
    http_status,
    status,
    detail,
    error: "",
    request_id: "",
  }
}

///|
/// A check the backend refused, keeping its own words.
fn Check::failed(
  label : String,
  failure : @api.Failure,
  detail : String,
) -> Check {
  {
    label,
    state: "fail",
    http_status: failure.http_status,
    status: failure.code,
    detail,
    error: failure.message,
    request_id: failure.request_id,
  }
}

///|
/// A check that did not run.
fn Check::skipped(label : String, detail : String) -> Check {
  {
    label,
    state: "skip",
    http_status: 0,
    status: 0,
    detail,
    error: "",
    request_id: "",
  }
}

///|
/// Whether this check failed.
fn Check::failed_(self : Check) -> Bool {
  self.state == "fail"
}

///|
/// One aligned terminal line: `[i/n] label  state  HTTP …  status=…  detail`.
fn Check::render(self : Check, index : Int32, total : Int32) -> String {
  let http : String = if self.http_status == 0 {
    ""
  } else {
    "HTTP \{self.http_status}  "
  }
  let status : String = if self.http_status == 0 {
    ""
  } else {
    "status=\{self.status}  "
  }
  let error : String = if self.error.is_empty() {
    ""
  } else {
    "error=\"\{self.error}\"  "
  }
  let request : String = if self.request_id.is_empty() {
    ""
  } else {
    "requestId=\{self.request_id}  "
  }
  "[\{index}/\{total}] \{self.label}  \{self.state}  \{http}\{status}\{error}\{request}\{self.detail}"
}

///|
/// The machine form of one check.
fn Check::json(self : Check) -> Json {
  {
    "label": Json(self.label),
    "state": Json(self.state),
    "httpStatus": Json(self.http_status),
    "status": Json(self.status),
    "detail": Json(self.detail),
    "error": Json(self.error),
    "requestId": Json(self.request_id),
  }
}

///|
/// How many of this machine's agents for a platform are actually usable.
/// `POST /agents/list` keeps disconnected agents in its result, so a row alone
/// does not mean "already registered" — only a connected one does.
fn connected_agents(items : Array[Json]) -> Int32 {
  let mut count = 0
  for item in items {
    let status = @api.string_field(item, "connectionStatus")
    if status.is_empty() || status == "connected" {
      count = count + 1
    }
  }
  count
}

///|
/// `field` of the agent-list row whose `id` is `agent_id`, or "".
fn listed_field(
  items : Array[Json],
  agent_id : String,
  field : String,
) -> String {
  for item in items {
    if @api.string_field(item, "id") == agent_id {
      return @api.string_field(item, field)
    }
  }
  ""
}

///|
/// The token prefix to verify against. A store written before prefixes were
/// recorded still has the token itself, and the backend's `tokenPrefix` is that
/// token's first eight characters — the same rule redaction uses.
fn effective_prefix(creds : @creds.Credentials) -> String {
  if !creds.token_prefix.is_empty() {
    creds.token_prefix
  } else if creds.agent_token.length() >= 8 {
    creds.agent_token[:8].to_owned()
  } else {
    ""
  }
}

///|
/// `everme-seekmoon doctor [--probe-platform] [--no-register]`.
async fn doctor_command(m : @argparse.Matches) -> Int32 {
  let paths = @config.Paths::resolve()
  let settings = @config.Settings::resolve()
  let machine = machine_of(m)
  let base = base_of(m, settings)
  let platform = platform_of(m, settings)
  let probe = flag_of(m, "probe-platform")
  let register = probe && !flag_of(m, "no-register")
  let creds = @creds.Credentials::load(paths.credentials_file())
  let fingerprint = @creds.machine_id(paths.machine_file())
  let checks : Array[Check] = []
  let client = @api.Client::new(base~).with_token(creds.api_key)

  // 1. Is a credential stored at all?
  if creds.has_api_key() {
    checks.push(
      Check::ok(
        "credential",
        0,
        0,
        "\{@redact.mask(creds.api_key)} at \{paths.credentials_file()}",
      ),
    )
  } else {
    checks.push(
      Check::skipped(
        "credential", "no API key stored (run `everme-seekmoon auth login` or `everme-seekmoon auth adopt-evercli`)",
      ),
    )
  }

  // 2. Does the backend accept it, and who is it?
  if creds.has_api_key() {
    let exchange = client.attempt("/auth/login", {
      "apiKey": Json(creds.api_key),
    })
    if exchange_ok(exchange) {
      let result = exchange.envelope.result
      let email = @api.string_field(result, "email")
      let scopes = @api.strings_field(result, "scopes").join(",")
      checks.push(
        Check::ok(
          "account",
          exchange.http_status,
          exchange.envelope.status,
          "\{email}  scopes=\{scopes}",
        ),
      )
    } else {
      checks.push(Check::failed("account", @api.failure_of(exchange), ""))
    }
  } else {
    checks.push(Check::skipped("account", "needs a stored credential"))
  }

  // 3. Is the stored agent token actually ours? A token whose owner we cannot
  // name is a token we must not use: it would attribute this CLI's memories to
  // another host's agent, and it would break the day that host rotates it.
  if creds.has_agent_token() && creds.has_api_key() {
    let listed = client.attempt("/agents/list", {
      "platform": Json(creds.platform),
      "machineFingerprint": Json(fingerprint),
    })
    if exchange_ok(listed) {
      let items : Array[Json] = match listed.envelope.result {
        Object(fields) =>
          match fields.get("items") {
            Some(Array(items)) => items
            _ => []
          }
        _ => []
      }
      match
        @creds.verify_agent(
          creds.agent_id,
          effective_prefix(creds),
          creds.platform,
          items,
        ) {
        Ok(_) => {
          // A store written before prefixes and labels were recorded still
          // passes on the agent id; record what the backend says now, so the
          // next run can be strict about both.
          let mut changed = false
          if creds.token_prefix.is_empty() && !creds.agent_token.is_empty() {
            creds.token_prefix = effective_prefix(creds)
            changed = true
          }
          if creds.platform.is_empty() {
            let recorded = listed_field(items, creds.agent_id, "platform")
            if !recorded.is_empty() {
              creds.platform = recorded
              changed = true
            }
          }
          if changed {
            creds.save(paths.credentials_file()) catch {
              _ => ()
            }
          }
          checks.push(
            Check::ok(
              "agent",
              listed.http_status,
              listed.envelope.status,
              "agentId=\{creds.agent_id}  token=\{effective_prefix(creds)}  platform=\{if creds.platform.is_empty() { "unrecorded" } else { creds.platform }}  (registered by this CLI)",
            ),
          )
        }
        Err(message) =>
          checks.push(
            Check::failed(
              "agent",
              {
                kind: "auth",
                message,
                hint: "run `everme-seekmoon doctor --probe-platform --platform <label>` to register this CLI's own agent",
                http_status: listed.http_status,
                code: listed.envelope.status,
                request_id: listed.envelope.request_id,
              },
              "stored token is not usable as this CLI's identity",
            ),
          )
      }
    } else {
      checks.push(Check::failed("agent", @api.failure_of(listed), ""))
    }
  } else {
    checks.push(
      Check::skipped(
        "agent", "no agent token stored yet (registration happens below)",
      ),
    )
  }

  // 4./5. The platform probe: list, then register only when nothing exists.
  let mut verdict : String = "not probed"
  if probe && !creds.has_api_key() {
    checks.push(Check::skipped("agents/list", "needs a stored credential"))
    checks.push(Check::skipped("agents", "needs a stored credential"))
    verdict = "not probed: no credential"
  } else if probe {
    let listed = client.attempt("/agents/list", {
      "platform": Json(platform),
      "machineFingerprint": Json(fingerprint),
    })
    let mut existing = 0
    let mut total = 0
    if exchange_ok(listed) {
      let items : Array[Json] = match listed.envelope.result {
        Object(fields) =>
          match fields.get("items") {
            Some(Array(items)) => items
            _ => []
          }
        _ => []
      }
      existing = connected_agents(items)
      total = items.length()
      checks.push(
        Check::ok(
          "agents/list",
          listed.http_status,
          listed.envelope.status,
          "platform \"\{platform}\"  connected agents: \{existing} of \{total}",
        ),
      )
    } else {
      checks.push(Check::failed("agents/list", @api.failure_of(listed), ""))
    }
    if exchange_ok(listed) && existing > 0 {
      checks.push(
        Check::skipped(
          "agents", "this machine already has an agent for this platform; nothing to register",
        ),
      )
      verdict = "accepted (already registered)"
    } else if !exchange_ok(listed) {
      checks.push(Check::skipped("agents", "listing failed first"))
      verdict = "inconclusive: the backend refused /agents/list"
    } else if !register {
      checks.push(Check::skipped("agents", "--no-register was passed"))
      verdict = "inconclusive: registration was skipped"
    } else {
      // One attempt under the configured label; a rejection is reported as the
      // backend worded it, not retried under another label.
      let outcome : Result[(Attempt, Registered), @api.Failure] = Ok(
        register_agent(client, fingerprint, platform, "SeekMoon"),
      ) catch {
        @api.ApiError(failure) => Err(failure)
        error => raise error
      }
      match outcome {
        Ok((attempt, registered)) => {
          // Keep what we minted: the agent, its token, and the label/prefix that
          // let a later run prove the token is still ours.
          creds.agent_id = registered.agent_id
          creds.agent_token = registered.agent_token
          creds.platform = registered.platform
          creds.token_prefix = registered.token_prefix
          creds.save(paths.credentials_file()) catch {
            _ => ()
          }
          checks.push(
            Check::ok(
              "agents",
              attempt.http_status,
              attempt.status,
              "platform \"\{attempt.platform}\" accepted  agentId=\{registered.agent_id}  token=\{@redact.mask(registered.agent_token)}",
            ),
          )
          verdict = "accepted: the backend registered platform \"\{registered.platform}\""
        }
        Err(failure) => {
          checks.push(Check::failed("agents", failure, ""))
          verdict = "rejected: platform \"\{platform}\" was refused (see the error above)"
        }
      }
    }
  }

  let failed = checks.any(check => check.failed_())
  let total = checks.length()
  let text = StringBuilder()
  text.write_string("everme-seekmoon doctor\n")
  text.write_string("  api      \{base}\n")
  // Two different labels belong in one report and must never be confused: the
  // one we asked for (`--platform`) and the one our stored agent actually has.
  text.write_string(
    "  want     \"\{platform}\"   (--platform / EVERME_PLATFORM: the label a probe registers under)\n",
  )
  text.write_string(
    "  ours     \{if creds.has_agent_token() { "\"\{if creds.platform.is_empty() { "unrecorded" } else { creds.platform }}\"  agent=\{creds.agent_id}  token=\{effective_prefix(creds)}" } else { "none  (no agent registered by this CLI yet)" }}\n",
  )
  text.write_string("  machine  \{fingerprint[:12]}…\n\n")
  for index, check in checks {
    text.write_string(check.render(index + 1, total))
    text.write_string("\n")
  }
  if probe {
    text.write_string("\nverdict: \{verdict}\n")
  }
  let data : Json = {
    "api": Json(base),
    "requestedPlatform": Json(platform),
    "agentPlatform": Json(creds.platform),
    "agentId": Json(creds.agent_id),
    "fingerprint": Json(fingerprint),
    "probed": Json(probe),
    "verdict": Json(verdict),
    "checks": Json(checks.map(check => check.json())),
  }
  emit(machine, text.to_string(), data)
  if failed {
    1
  } else {
    0
  }
}
