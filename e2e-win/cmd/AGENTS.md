# CLAUDE.md — cmd.exe / Clink Shell Integration

Guidance for AI agents (and humans) working on mise's **cmd.exe shell
integration**. This is the companion to the task list in
[docs/issues/cmd-shell-integration.md](../../docs/issues/cmd-shell-integration.md).
Read that file for the remaining-work checklist; read this file for *how to work
on it and how to validate changes*.

`AGENTS.md` in this directory symlinks to this file for non-Claude agents.

## What this integration is

cmd.exe has no native scripting hook for "run code when the prompt is drawn" or
"intercept a command". mise's cmd support therefore targets
[Clink](https://chrisant996.github.io/clink/) — a readline replacement for
cmd.exe that embeds **Lua 5.4**. `mise activate cmd` emits a Lua script that
Clink loads, which:

- sets `MISE_SHELL=cmd`
- registers a `clink.onbeginedit` hook that runs `mise hook-env -s cmd` on
  directory change and `load()`s the returned Lua to mutate the environment
- writes a tiny temp "bridge" script and a `doskey mise=lua "<bridge>" $*`
  macro so that `mise shell` / `mise deactivate` can apply env changes in-process

Key fact that makes everything testable: **Clink's Lua is stock Lua 5.4**, plus
a handful of injected globals (`os.setenv`, `clink.onbeginedit`,
`clink.argmatcher`, …). A normal `lua` 5.4 binary can parse and — with those
globals mocked — *run* the emitted scripts.

## Source files

| File | Role |
|------|------|
| [`src/shell/cmd.rs`](../../src/shell/cmd.rs) | The `Shell` impl: `activate`/`deactivate`/`set_env`/`prepend_env`/`unset_env`. This is where the emitted Lua is generated. |
| [`src/shell/mod.rs`](../../src/shell/mod.rs) | `ShellType::Cmd` enum wiring (`FromStr`, `Display`, `as_shell`). |
| [`src/task/task_script_parser.rs`](../../src/task/task_script_parser.rs) | Task arg escaping; the `Cmd` branch must escape cmd metacharacters. |
| [`src/cli/completion.rs`](../../src/cli/completion.rs) | Completion generation (Clink argmatcher lives here / in `completions/`). |

## The validation harness (USE THIS TO ITERATE)

Everything here lets you change `cmd.rs` and get a pass/fail in seconds without a
live cmd.exe + Clink session.

```
e2e-win/cmd/
  mock_clink.lua   Emulates the Clink/cmd Lua environment (os.setenv,
                   clink.*, io.popen, os.execute, os.tmpname, io.open) and
                   RECORDS every interaction so tests can assert on them.
  run_tests.lua    Pure validator. Reads pre-captured fixture files and runs
                   each emitted script inside the mock. NEVER spawns a process.
  validate.ps1     Driver. Captures `mise activate cmd` / `hook-env -s cmd` /
                   `deactivate` to fixture files, then runs run_tests.lua.
```

### How to run it

```bash
# Fastest loop — via the mise task (builds first, then validates):
mise run test:cmd

# Or drive the PowerShell capture + Lua validator directly:
pwsh -NoProfile -File e2e-win/cmd/validate.ps1 -MiseExe target/debug/mise.exe

# Or, if you already have fixture files in a dir, validate only:
lua e2e-win/cmd/run_tests.lua <fixtures-dir>
```

The same validator runs as a Pester e2e test:
[`e2e-win/cmd_activate.Tests.ps1`](../cmd_activate.Tests.ps1) (run via
`pwsh -File e2e-win/run.ps1 -TestName "cmd_activate*"`). It **skips** (does not
fail) when no Lua 5.4 interpreter is present, so CI without Lua stays green.

### Why capture is split from validation (IMPORTANT)

The Lua validator does **not** call `mise` itself. Capture is done by
`validate.ps1` using PowerShell's call operator (`& mise ...`), which invokes
the executable through `CreateProcess`. This deliberately avoids `io.popen`,
because `io.popen` shells out through `cmd.exe`, and a developer machine may
have a **cmd.exe AutoRun** customization (clink injection, dotfile bootstrap,
etc.) that prints a banner or drops into an interactive prompt — corrupting or
emptying the captured output. If you add new capture steps, keep them in
PowerShell with `&`, never via `cmd /c`.

### Prerequisites

- **Lua 5.4** on PATH (`scoop install lua`, or `mise use lua@5.4`). Must be 5.4
  to match Clink; 5.1 would reject `load(s, name, "t")` and other 5.4 syntax.
- A built mise (`mise run build` → `target/debug/mise.exe`).
- Clink is **not** required for the harness — only for a real interactive
  smoke test (see the manual steps in the issue doc).

## Working rules for this integration

1. **After any change to `cmd.rs`, run `mise run test:cmd`.** Add a new check to
   `run_tests.lua` for any behavior you add or fix, so it can't regress.
2. **Do not assume Clink globals exist in stock Lua.** If `cmd.rs` starts using
   a new Clink API (e.g. `clink.promptfilter`), add a mock for it in
   `mock_clink.lua` or the validator will throw a runtime error.
3. **The emitted script must always be valid Lua 5.4**, even on the error paths.
   `run_tests.lua` `load()`s it first; a syntax error fails fast.
4. **Quoting/escaping is the main hazard.** Paths and env values flow into Lua
   string literals (`escape_lua_string`) and, for tasks, into cmd command lines.
   When touching escaping, add a fixture/check with nasty input (`&`, `|`, `%`,
   `^`, spaces, quotes, backslashes).
5. **Snapshot tests** in `cmd.rs` (`cargo insta test`) cover the *exact text*;
   the Lua harness covers *behavior*. Keep both — they catch different bugs.
6. **Keep the issue doc current.** Tick items in
   `docs/issues/cmd-shell-integration.md` as you complete them and append any
   new gaps you discover.
