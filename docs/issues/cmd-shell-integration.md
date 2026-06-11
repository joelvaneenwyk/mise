# Cmd.exe Shell Integration — Remaining Work

**Status**: Active — activation implemented; validation harness + most integration gaps now closed
**Branch**: `main` (joelvaneenwyk/mise fork)
**Upstream**: `jdx/mise`

## Overview

The cmd.exe shell integration uses [Clink](https://chrisant996.github.io/clink/) (a readline replacement for cmd.exe that embeds a Lua scripting engine). The `mise activate cmd` command emits a Lua script that:

- Sets a `doskey` macro for the `mise` command
- Hooks into `clink.onbeginedit` for directory-change detection
- Calls `mise hook-env -s cmd` and evals the returned Lua code
- Handles `mise shell` / `mise deactivate` by capturing and executing their Lua output

## Files Touched

| File | Purpose |
|------|---------|
| `src/shell/cmd.rs` | Shell trait impl — activate/deactivate/set_env/prepend_env/unset_env (+ snapshot tests) |
| `src/shell/mod.rs` | `Cmd` variant in `ShellType` enum, `FromStr`, `Display` |
| `src/shell/snapshots/mise__shell__cmd__tests__*.snap` | Snapshot tests (prepend_env, activate, deactivate) |
| `src/task/task_script_parser.rs` | `cmd_quote` escaping for cmd task args (+ unit test) |
| `src/cli/completion.rs` | `Cmd` completion variant → prerendered Clink argmatcher |
| `completions/mise.lua` | Clink argmatcher completion script |
| `mise.usage.kdl` + `docs/cli/{activate,env}.md` + `docs/getting-started.md` | `cmd` shell choice / docs |
| `e2e-win/cmd/` | **Validation harness** (see below) |
| `e2e-win/cmd_activate.Tests.ps1` | Pester e2e test running the harness |
| `tasks.toml` | `test:cmd` task |

## Programmatic Validation Harness (DONE — use this to iterate)

The critical enabler: a way to validate the integration **without a live cmd.exe + Clink session**. Clink's Lua is stock **Lua 5.4** plus injected globals (`os.setenv`, `clink.*`), so a normal `lua` 5.4 binary can parse and — with those globals mocked — run the emitted scripts.

```
e2e-win/cmd/
  mock_clink.lua   Emulates the Clink/cmd Lua environment and records every
                   interaction (env mutations, popen/execute, onbeginedit
                   callbacks, doskey, temp files, argmatcher registrations).
  run_tests.lua    Pure validator: reads pre-captured fixtures and runs each
                   emitted script inside the mock. Never spawns a process.
  validate.ps1     Driver: captures `activate` / `hook-env` / `deactivate` /
                   `completion` output to fixtures (via PowerShell `&`, which
                   bypasses cmd.exe AutoRun), then runs run_tests.lua.
  CLAUDE.md        Guidance for agents working on this integration.
```

Run it any of these ways:

```bash
mise run test:cmd                                              # build + validate
pwsh -NoProfile -File e2e-win/cmd/validate.ps1                 # capture + validate
lua e2e-win/cmd/run_tests.lua <fixtures-dir>                   # validate only
pwsh -File e2e-win/run.ps1 -TestName "cmd_activate*"           # via Pester
```

Currently **27 behavioral checks** pass, covering syntax validity, activation
(MISE_SHELL, onbeginedit hook + directory-change re-run, doskey macro, bridge
file, hook-env eval), hook-env output, env primitives, deactivate teardown, and
the completion argmatcher.

> **Why capture is split from validation:** the Lua validator never calls mise.
> `io.popen` shells out through `cmd.exe`, and a dev machine may have a cmd.exe
> AutoRun customization (clink injection, dotfile bootstrap) that pollutes or
> empties captured output. `validate.ps1` captures via PowerShell's `&`
> (CreateProcess, no cmd layer). Keep all capture in PowerShell, never `cmd /c`.

## Remaining Work

### 1. Task Script Escaping — ✅ DONE

**File**: `src/task/task_script_parser.rs`

Added `cmd_quote()` and a `Some(ShellType::Cmd)` branch in the arg-escape
closure (parallel to `shell_words::quote` for bash/zsh/fish), plus a unit test
(`test_cmd_quote`).

**Correction to the original plan:** the previously-suggested `%` → `%%`
escaping is **wrong** here. Windows tasks run as `cmd /c <script>` with the
script as a single argv element — i.e. the cmd *command line*, not a batch file.
`%%` only collapses to `%` inside batch files; on the command line it would
leave a literal `%%`. Instead `cmd_quote` wraps values containing whitespace or
cmd metacharacters in double quotes (inside which cmd treats `& | < > ( ) ^`
literally), doubling embedded quotes. This neutralizes the command-injection
vectors.

**Known limitation (new task #8 below):** `%VAR%` and `!VAR!` (delayed
expansion) are still expanded by cmd even inside double quotes, and there is no
reliable command-line escape for them. Quoting prevents command execution; it
cannot fully prevent variable expansion.

### 2. Documentation Updates — ✅ DONE

`cmd` added to the `--shell` choices in `mise.usage.kdl` (source of truth) and
the generated `docs/cli/activate.md` / `docs/cli/env.md`, plus a Clink
activation example in `docs/getting-started.md`.

> Note: a full `mise run render:usage` regenerates *every* `docs/cli/*.md` and
> currently produces large unrelated formatting drift (the committed docs were
> generated by an older `usage` version). The edits here were therefore applied
> surgically to match what regeneration would add for `cmd`. A future cleanup
> could re-baseline all CLI docs with the current `usage` tool in one commit.

### 3. Shell Completions — ✅ DONE

**Files**: `src/cli/completion.rs`, `completions/mise.lua`

Added a `Cmd` variant to the completion `Shell` enum that emits a prerendered
Clink argmatcher (`completions/mise.lua`). The argmatcher completes top-level
subcommands and global flags, and does dynamic task-name completion for
`mise run` / `mise r` via `mise tasks ls`. `mise completion cmd` short-circuits
the `usage`-based path (usage has no Clink target). The script guards on `clink`
so it loads harmlessly outside Clink. Validated by the harness.

**Follow-up (new task #9 below):** completion currently only resolves task names
for `run`. Tool-name completion for `use`/`install`/`uninstall` and setting
names for `settings` would be nice-to-have.

### 4. `hook-env` Output Format — ✅ VERIFIED

The harness captures `mise hook-env -s cmd`, confirms it is valid Lua, runs it
in the mock, and asserts it performs `os.setenv` mutations and does **not** shell
out. The activation test also feeds a representative hook-env response and
asserts the activate script `load()`s and applies it.

### 5. Unit Test Coverage — ✅ DONE

`src/shell/cmd.rs` now has a `#[cfg(test)]` module with snapshots for `set_env`
(inline), `unset_env` (inline), a special-char `set_env` escaping case (inline),
`prepend_env` (file), `activate` (file, fixed exe path for determinism), and
`deactivate` (file). The Lua harness complements these with behavioral checks.

### 6. E2E Tests — ✅ DONE

`e2e-win/cmd_activate.Tests.ps1` runs the validator under Pester. It **skips**
(does not fail) when no Lua 5.4 interpreter is present, so CI without Lua stays
green. Locally install Lua with `scoop install lua` or `mise use lua@5.4`.

### 7. Shell Aliases — UNCHANGED (acceptable)

`set_alias` / `unset_alias` still use the default no-op. `doskey` macros could
serve this purpose in future but this is not required.

## New Tasks / Findings (discovered during this work)

### 8. `%`/`!` expansion in cmd task args (LOW — documented limitation)

As noted under item #1, double-quoting cannot suppress `%VAR%`/`!VAR!`
expansion on the cmd command line. If a use case needs literal `%`/`!` in a task
argument, the value should be passed via the environment rather than
interpolated into the command line. No code fix planned unless a concrete need
arises; documented in `cmd_quote`'s doc comment.

### 9. Richer completion (LOW — quality of life)

`completions/mise.lua` only completes task names for `mise run`. Could extend to
tool names (`use`/`install`) and setting keys (`settings`). These are more
expensive to enumerate and may warrant caching.

### 10. Dead fallback branch in `deactivate()` (LOW — cleanup)

`src/shell/cmd.rs::deactivate` has an `else` branch referencing
`_G._mise_internal_handler.script_file_path_for_cleanup`, which is never set
(the handler is a plain function). It is harmless but dead. Consider removing it
to simplify the generated script.

### 11. `__MISE_ORIG_PATH` handling (VERIFY — possible parity gap)

`activate` leaves a commented-out `__MISE_ORIG_PATH` line. Other shells rely on
mise's standard PATH handling via hook-env; confirm cmd doesn't need this and
remove the comment, or wire it up if a PATH-restore edge case is found.

## Prerequisites for Testing

- **Lua 5.4** on PATH (`scoop install lua` or `mise use lua@5.4`) — must be 5.4
  to match Clink (5.1 would reject `load(s, name, "t")` and other 5.4 syntax).
- A built mise (`mise run build`).
- **Clink** is only needed for a real interactive smoke test (see below); the
  harness does not require it.

## Architecture Notes

```
┌──────────────────┐
│  cmd.exe + Clink │
└────────┬─────────┘
         │ loads Lua script from mise activate cmd
         ▼
┌──────────────────────────────────────────┐
│  Generated Lua Script                     │
│  - Sets MISE_SHELL=cmd                    │
│  - Creates temp .lua for doskey bridge    │
│  - doskey mise=lua "<temp>.lua" $*        │
│  - clink.onbeginedit → _mise_hook()       │
│  - _mise_hook() → io.popen(hook-env)      │
│     → safe_load_and_run(result)           │
└──────────────────────────────────────────┘
         │
         │ hook-env returns Lua code:
         │   os.setenv("X","Y")
         │   os.setenv("PATH", "..." .. ";" .. os.getenv("PATH"))
         ▼
┌──────────────────┐
│ Environment is   │
│ modified in-proc │
└──────────────────┘
```

## Quick Reference: Running Manually

```cmd
:: Install clink (e.g., via scoop or GitHub releases)
scoop install clink

:: Build mise
cargo build --features clap_mangen

:: Generate activation script and load it
target\debug\mise.exe activate cmd > %LOCALAPPDATA%\clink\mise.lua

:: Optionally, completions
target\debug\mise.exe completion cmd > %LOCALAPPDATA%\clink\mise-completion.lua

:: Restart cmd.exe (clink auto-loads scripts from its profile dir)
```
