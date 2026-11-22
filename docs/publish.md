# Publishing this skill to the MoonBit skills marketplace

`mooncakes.io/skills` is the marketplace; the client that talks to it is
`skills`, from [moonbit-community/skills](https://github.com/moonbit-community/skills).
It is not a `moon` subcommand — install it first:

```bash
moon install moonbit-community/skills
```

The marketplace lists two things, and this project ships both halves:

- **the skill** — `SKILL.md` plus the `mcp.json` that registers the server;
- **the server itself** — a MoonBit package compiled to wasm and run by `moonx`:
  `moonx chaijie2018/EverMe-for-SeekMoon/cmd/everme-seekmoon@0.1.0 mcp serve`.

The skill is published here; the package is published to the module registry
with `moon publish`. Publish the module **first** — until that version exists,
the coordinate in `mcp.json` resolves to nothing.

## 1. Build the skill directory

```bash
moon run tools/gen-skill -- --out /tmp/everme-seekmoon-skill
```

Three files, none of which names this machine:

| File | Content |
|---|---|
| `SKILL.md` | the rendered skill (from `docs/SKILL.template.md`) |
| `mcp.json` | `{"mcpServers":{"everme-seekmoon":{"command":"moonx","args":["chaijie2018/EverMe-for-SeekMoon/cmd/everme-seekmoon@0.1.0","mcp","serve"]}}}` |
| `README.md` | what it is, how to run it, license |

`--dry-run` reports the files and writes nothing.

## 2. Log in

```bash
moon login
```

That writes a 32-hex publish token to `$MOON_HOME/credentials.json`
(`~/.moon/credentials.json` by default).

## 3. Publish

```bash
skills publish /tmp/everme-seekmoon-skill --version 0.1.0
```

What the client does: zip the directory → validate `SKILL.md`, the paths and the
sizes locally → read the Bearer token → `POST
https://mooncakes.io/api/v0/skills?version=0.1.0` → compare the `archive_digest`
the server returns with the local SHA-256. The version must be SemVer 2.0.0 and
is **immutable** once published.

## What the server enforces, and what `tools/gen-skill` checks first

| Rule | Value | This skill |
|---|---|---|
| `name` | 1–64 chars of `a-z`, `0-9`, single `-`; no leading, trailing or doubled `-` | `everme-seekmoon` ✅ |
| `description` | non-empty, ≤ 1024 characters | ~300 ✅ |
| `SKILL.md` | UTF-8, ≤ 256 KiB | ~4.7 KB ✅ |
| archive | regular files and directories only (no symlinks, no device files), ≤ 2000 entries, zip ≤ 20 MiB, unpacked ≤ 50 MiB | 3 files ✅ |
| `version` | SemVer 2.0.0, immutable | `0.1.0` |

`tools/gen-skill` refuses to write a directory whose rendered skill fails the frontmatter
or size rules (`publish_problems()`), because an upload the server rejects burns a
version number that can never be reused.

## How the two halves connect

1. The agent downloads the skill and reads `SKILL.md`.
2. `mcp.json` registers `everme-seekmoon` with `command: "moonx"` and the pinned
   coordinate — the host launches the server without any path from this machine.
3. `moonx` resolves that coordinate from the registry, verifies the archive
   digest, caches the wasm under `$MOON_HOME/registry/cache/assets`, and runs it.

## Why the skill is published separately from the code

1. **Different release cadence**: `SKILL.md` changes often (sharper triggers,
   better examples, new boundaries); the library behind it does not. Publishing a
   skill must not require rebuilding and republishing a module, and a module patch
   must not force every agent to re-download the instructions.
2. **Not one-to-one**: one skill can drive several modules, a methodology-only
   skill has no module at all, and one module can back several skills.
3. **Portability**: a skill is a `SKILL.md` in a zip, which any client that speaks
   the Agent Skills convention can use — no knowledge of `moon.mod`, packages or
   the dependency graph required.
4. **A clearer security boundary**: downloading a skill is fetching checked,
   symlink-free documents; running external code is a separate step, gated by
   `moonx` and its `--experimental-policy` sandbox.

SeekMoon's own registry splits the two for the same reason — its skill registry
carries the note that a standalone skill has no package path.

## What stays as it is

- The skill directory `tools/gen-skill -- --out <dir>` writes is the whole of what
  SeekMoon needs: `SKILL.md` beside `mcp.json` in a skills library, whether that
  copy came from the marketplace, from a zip, or directly from this generator. There
  is no second copy for the CLI to write, and therefore nothing for it to drift against.
- `docs/SKILL.template.md` is the single source: `moon run tools/gen-skill` keeps
  `docs/SKILL.md` in step, `moon run tools/gen-skill -- --check` verifies both sync
  and marketplace rules, and `moon test` fails when they drift.
