# Cmd.exe Shell Integration — Remaining Work

**Status**: WIP — Activation script implemented, integration gaps remain
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
| `src/shell/cmd.rs` | Shell trait impl — activate/deactivate/set_env/prepend_env/unset_env |
| `src/shell/mod.rs` | `Cmd` variant in `ShellType` enum, `FromStr`, `Display` |
| `src/shell/snapshots/mise__shell__cmd__tests__prepend_env.snap` | Snapshot test |
| `taskfile.yaml` | Build workflow (unrelated to cmd shell, but part of fork) |

## Remaining Work

### 1. Task Script Escaping (HIGH — potential command injection)

**File**: `src/task/task_script_parser.rs`

The task script parser has shell-aware command escaping but only handles `Bash | Zsh | Fish`. The `Cmd` variant falls through to an unescaped `_ => v.to_string()` branch. This means task arguments containing special characters (`&`, `|`, `>`, `<`, `^`, `%`) won't be escaped when the task shell is cmd.

**Fix**: Add a cmd-specific escaping branch that wraps values or uses `^` escape sequences for cmd metacharacters.

```rust
// Approximate fix in task_script_parser.rs
Some(ShellType::Cmd) => {
    // Escape cmd.exe metacharacters with ^
    v.to_string()
        .replace('^', "^^")
        .replace('&', "^&")
        .replace('|', "^|")
        .replace('<', "^<")
        .replace('>', "^>")
        .replace('%', "%%")
}
```

### 2. Documentation Updates (HIGH — discoverability)

The following docs list shell choices but omit `cmd`:

| File | Section |
|------|---------|
| `docs/cli/activate.md` | `--shell` choices |
| `docs/cli/env.md` | `--shell` choices |
| `docs/getting-started.md` | Activation examples |

These are auto-generated from `mise.usage.kdl` / `settings.toml`, so the fix may be to update the source of truth (the `ShellType` clap enum already includes `Cmd`, so re-running `mise run render:usage` may pick it up).

### 3. Shell Completions (MEDIUM — quality of life)

**File**: `src/cli/completion.rs`

Only bash/fish/zsh/pwsh have prerendered completion scripts. Cmd.exe doesn't have a native completion mechanism, but Clink supports Lua-based completers. A completion script could be generated that uses `clink.argmatcher` to provide tab-completion.

**Suggested approach**: Create `completions/mise.lua` (Clink argmatcher) and wire it into the completion command.

### 4. `hook-env` Output Format (VERIFY)

The `hook-env -s cmd` flag needs to output Lua code that Clink can evaluate. Verify that:
- `set_env` / `prepend_env` / `unset_env` output from hook-env matches what `cmd.rs` generates
- The hook-env output doesn't include shell syntax from another format

This should already work if the shell dispatch in `hook_env.rs` uses `ShellType::Cmd.as_shell()` — but it should be tested end-to-end.

### 5. Unit Test Coverage (LOW — code quality)

**Current**: Only `prepend_env` has a snapshot test.

**Missing snapshots**:
- `set_env`
- `unset_env`
- `activate` (at least verify it produces valid Lua)
- `deactivate`

**Suggested**: Add a `#[cfg(test)]` module in `cmd.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::ActivateOptions;
    use insta::assert_snapshot;
    use std::path::PathBuf;

    fn replace_path(s: &str) -> String {
        s.replace(env!("CARGO_HOME"), "/CARGO_HOME")
    }

    #[test]
    fn test_set_env() {
        let cmd = Cmd::default();
        assert_snapshot!(cmd.set_env("FOO", "bar"));
    }

    #[test]
    fn test_unset_env() {
        let cmd = Cmd::default();
        assert_snapshot!(cmd.unset_env("FOO"));
    }

    #[test]
    fn test_prepend_env() {
        let cmd = Cmd::default();
        assert_snapshot!(replace_path(&cmd.prepend_env("PATH", "/some/dir:/2/dir")));
    }
}
```

### 6. E2E Tests (LOW — regression prevention)

No e2e tests exist for `mise activate cmd`. The `e2e-win/` directory has PowerShell-based tests but nothing for cmd.exe.

**Suggested**: Add `e2e-win/cmd-activate.Tests.ps1` that:
1. Starts a cmd.exe subprocess with Clink
2. Sources the `mise activate cmd` output
3. Verifies `MISE_SHELL` is set to `cmd`
4. Verifies tool shims are on PATH after activation

### 7. Shell Aliases (LOW — known limitation)

The `set_alias` / `unset_alias` trait methods use the default no-op implementation. Cmd.exe doesn't have native aliases, but `doskey` macros could serve this purpose. This is acceptable as-is for now.

## Prerequisites for Testing

- **Clink** must be installed and configured with cmd.exe
- The activation script is designed for Clink's embedded Lua 5.4
- Standard cmd.exe without Clink cannot run the activation script

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
│  - clink.onbeginedit → _mise_hook()      │
│  - _mise_hook() → io.popen(hook-env)     │
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

:: Restart cmd.exe (clink auto-loads scripts from its profile dir)
```
