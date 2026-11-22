# EverMe-for-SeekMoon

`everme-seekmoon` — a MoonBit CLI that connects [SeekMoon](https://github.com/moonbitlang/openseek) to
[EverMe](https://github.com/EverMind-AI/EverMe) memory: one pool shared across the
user's devices and agents.

It is two things in one binary:

- **an MCP server** (`everme-seekmoon mcp serve`) speaking the EverMe memory contract over
  stdio — tools `mem_context`, `mem_search`, `mem_save_fact`, `mem_save_turn` and
  resources `mem://profile`, `mem://search?q=…` — which SeekMoon launches;
- **a CLI** that logs in, binds this machine as an agent, and imports existing
  conversation history.

It is not a reimplementation of upstream `evercli`: only the parts SeekMoon needs,
written in MoonBit so the server has no Node dependency. The two can coexist — they
share an account and its memory, and `everme-seekmoon auth adopt-evercli` reuses an existing
evercli login.

## Install

The server is a MoonBit package: the skill's `mcp.json` launches
`moonx chaijie2018/EverMe-for-SeekMoon/cmd/everme-seekmoon@0.1.1 mcp serve`.
`moonx` comes with the toolchain and resolves that pinned version from the
registry, so no absolute path is recorded and a rebuild or a moved checkout cannot
break the host. Nothing on this side installs files: the skill directory ships
the config, and a skills library is where it lives.

```bash
# 1. log in — this also binds this machine as an agent
moon run --release cmd/everme-seekmoon -- auth login     # or: auth adopt-evercli

# 2. put the skill where SeekMoon reads skills (see "Publish" for how to build it)
#    e.g. ~/.openseek/skills/everme-seekmoon/ with SKILL.md and mcp.json

# 3. (optional) bring earlier conversations in
moon run --release cmd/everme-seekmoon -- import sessions

# 4. check
moon run --release cmd/everme-seekmoon -- doctor
moon run --release cmd/everme-seekmoon -- mcp test
```

`auth login` stores the account key, registers this machine's agent when the
credential has none, and prints the agent id it holds. Logging in to a different
account drops the agent this CLI had instead of carrying its token over. `auth
register` does the binding on demand, and asks the account whether the agent it
holds is still listed — a token retired from another machine or by `evercli` is
replaced rather than reused. It is also the repair path for a dropped token or a
platform label the backend refused, and is idempotent.

The skill text itself lives in `docs/SKILL.template.md`, where it can be edited and
previewed as a document. `moon run tools/gen-skill` renders it into `docs/SKILL.md`,
and `moon test` fails when the two fall out of step, so the markdown really is the
source.

## Build targets

`moon.mod` sets `preferred_target = "wasm"`: the default `build`, `test` and `run`
are the wasm ones, and that is the artifact `moonx` executes for a host. Native
stays available (`+native +wasm` in every package) when a faster local loop helps:

```bash
moon build cmd/everme-seekmoon                    # wasm — what moonx runs
moon run cmd/everme-seekmoon -- doctor            # wasm, under moonrun
moon build --target native cmd/everme-seekmoon    # optional: native
```

Verified on wasm: `doctor` reached the gateway over HTTPS (`HTTP 200` for account
and agent), and `mcp test` completed a real `mem_context`.

## Publish

`moon run tools/gen-skill -- --out <dir>` writes the directory the MoonBit skills
marketplace accepts: the rendered `SKILL.md`, the `moonx`-based `mcp.json`, and a
`README.md`. Zip it and publish — see [docs/publish.md](docs/publish.md) for the
three steps and the archive rules.

Reopen the workspace in SeekMoon afterwards and ask "what do you remember about me?".

## Commands

| Command | What it does |
|---|---|
| `auth login` / `status` / `logout` | Device-flow login; `--no-wait` and `--device-code` split it across processes |
| `auth adopt-evercli` | Reuse an evercli login on this machine (account key only, never its agent token) |
| `auth register` | Bind this machine as an agent of the account; idempotent, and what `auth login` does on the way out |
| `auth disconnect-agent --agent-id ID` | Retire an agent; drops the stored token when it is ours |
| `doctor [--probe-platform]` | Credential, account, agent identity, and (with the flag) the platform label |
| `mcp serve` / `mcp test` | The stdio server / a self-check with one real `mem_context` |
| `import sessions` | Incremental import of `~/.openseek/sessions/*/*.jsonl` |

`--format json` switches stdout to `{"ok":…}` / `{"ok":false,"error":{…}}` envelopes
with the same `error.type` taxonomy and exit codes as upstream.

## What it writes

| Path | Contents |
|---|---|
| `~/.local/share/everme-seekmoon/credentials.json` | `0600`: the `emk_` account key and this CLI's own `evt_` agent token |
| `~/.local/share/everme-seekmoon/credentials.json.lock` | Empty; serialises registration so two logins cannot mint two agents |
| `~/.config/everme-seekmoon/account.json` | Cached account snapshot (no secrets) |
| `~/.local/share/everme-seekmoon/import-state.json` | Per-session import cursor |

Nothing here writes a skills library: `~/.openseek/skills/everme-seekmoon/`
(`SKILL.md` + `mcp.json`) is the skill itself, either generated by
`tools/gen-skill -- --out` and unpacked, or downloaded from the marketplace.

Tokens never reach `mcp.json`, logs, or error messages: the server reads its own
credential store, and every outward string is redacted (`emk_…` / `evt_…` keep
eight characters).

## Notes

- The managed backend validates `platform` against its own list; `seekmoon` is not in
  it, so this CLI registers as `evercli` (override with `--platform`).
- Memory writes are at-least-once: an import interrupted mid-batch can repeat that
  batch. The per-batch cursor keeps everything else from being re-sent.

Licensed under [Apache-2.0](LICENSE).
