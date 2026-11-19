# EverMe-for-SeekMoon

`everme` — a MoonBit CLI that connects [SeekMoon](https://github.com/moonbitlang/openseek) to
[EverMe](https://github.com/EverMind-AI/EverMe) memory: one pool shared across the
user's devices and agents.

It is two things in one binary:

- **an MCP server** (`everme mcp serve`) speaking the EverMe memory contract over
  stdio — tools `mem_context`, `mem_search`, `mem_save_fact`, `mem_save_turn` and
  resources `mem://profile`, `mem://search?q=…` — which SeekMoon launches;
- **a CLI** that logs in, registers this machine's agent, installs the skill bundle
  SeekMoon reads, and imports existing conversation history.

It is not a reimplementation of upstream `evercli`: only the parts SeekMoon needs,
written in MoonBit so the server has no Node dependency. The two can coexist — they
share an account and its memory, and `everme auth adopt-evercli` reuses an existing
evercli login.

## Install

```bash
# 1. build, then keep a copy outside the build tree
moon build --release
_build/native/release/build/cmd/everme/everme install --copy-to ~/.local/bin

# 2. (optional) bring earlier conversations in
~/.local/bin/everme import sessions

# 3. check
~/.local/bin/everme doctor
~/.local/bin/everme mcp test
```

`install` registers this machine's agent if the credential has none, writes the
skill bundle to `~/.openseek/skills/everme-memory/`, and prints the label it
registered under. `--mode mcp-json` merges `~/.openseek/mcp.json` instead (or as
well, with `both`), keeping a `<path>.bak` of the previous file. `--agents-md` adds
a marked block to the workspace's `AGENTS.md`.

Reopen the workspace in SeekMoon afterwards and ask "what do you remember about me?".

## Commands

| Command | What it does |
|---|---|
| `auth login` / `status` / `logout` | Device-flow login; `--no-wait` and `--device-code` split it across processes |
| `auth adopt-evercli` | Reuse an evercli login on this machine (account key only, never its agent token) |
| `auth disconnect-agent --agent-id ID` | Retire an agent; drops the stored token when it is ours |
| `install` / `uninstall` | Depth: skill bundle, shared config, `AGENTS.md`; `--dry-run` first |
| `doctor [--probe-platform]` | Credential, account, agent identity, and (with the flag) the platform label |
| `mcp serve` / `mcp test` | The stdio server / a self-check with one real `mem_context` |
| `import sessions` | Incremental import of `~/.openseek/sessions/*/*.jsonl` |

`--format json` switches stdout to `{"ok":…}` / `{"ok":false,"error":{…}}` envelopes
with the same `error.type` taxonomy and exit codes as upstream.

## What it writes

| Path | Contents |
|---|---|
| `~/.local/share/everme/credentials.json` | `0600`: the `emk_` account key and this CLI's own `evt_` agent token |
| `~/.config/everme/account.json` | Cached account snapshot (no secrets) |
| `~/.local/share/everme/import-state.json` | Per-session import cursor |
| `~/.openseek/skills/everme-memory/` | `SKILL.md` + `mcp.json` for SeekMoon (from `install`) |

Tokens never reach `mcp.json`, logs, or error messages: the server reads its own
credential store, and every outward string is redacted (`emk_…` / `evt_…` keep
eight characters).

## Notes

- The managed backend validates `platform` against its own list; `seekmoon` is not in
  it, so this CLI registers as `evercli` (override with `--platform`).
- Memory writes are at-least-once: an import interrupted mid-batch can repeat that
  batch. The per-batch cursor keeps everything else from being re-sent.

Licensed under Apache-2.0.
