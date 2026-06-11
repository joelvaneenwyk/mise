-- Clink argmatcher for mise (https://mise.en.dev)
--
-- cmd.exe has no native completion engine, but Clink (https://chrisant996.github.io/clink/)
-- — the same readline/Lua layer that powers `mise activate cmd` — provides one
-- via clink.argmatcher. Install this script into Clink's autostart directory:
--
--     mise completion cmd > "%LOCALAPPDATA%\clink\mise-completion.lua"
--
-- and restart cmd.exe. Completion covers the top-level subcommands and global
-- flags, with dynamic task-name completion for `mise run`.

if not clink or not clink.argmatcher then
    -- Loaded outside Clink (e.g. bare cmd.exe or a syntax check). Nothing to do.
    return
end

-- Run a command and return its stdout as a list of trimmed, non-empty lines.
local function read_lines(command)
    local lines = {}
    local handle = io.popen(command)
    if not handle then
        return lines
    end
    for line in handle:lines() do
        line = line:gsub("%s+$", "")
        if #line > 0 then
            lines[#lines + 1] = line
        end
    end
    handle:close()
    return lines
end

-- Dynamic completion of task names for `mise run`. mise prints tasks as
-- "name<whitespace>description"; we take the first column. Errors (no config,
-- mise not yet on PATH) degrade gracefully to an empty list.
local function mise_tasks()
    local tasks = {}
    for _, line in ipairs(read_lines("mise tasks ls --no-header 2>nul")) do
        local name = line:match("^(%S+)")
        if name then
            tasks[#tasks + 1] = name
        end
    end
    return tasks
end

-- Top-level subcommands (kept in sync with `mise --help`).
local commands = {
    "activate", "backends", "bin-paths", "cache", "completion", "config",
    "deactivate", "deps", "doctor", "edit", "en", "env", "exec", "fmt",
    "generate", "help", "implode", "install", "install-into", "latest", "link",
    "lock", "ls", "ls-remote", "mcp", "oci", "outdated", "patrons", "plugins",
    "prune", "registry", "reshim", "run", "search", "self-update", "set",
    "settings", "shell", "shell-alias", "sponsors", "sync", "tasks",
    "test-tool", "token", "tool", "tool-alias", "tool-stub", "trust",
    "uninstall", "unset", "untrust", "unuse", "upgrade", "use", "version",
    "watch", "where", "which",
}

-- Global flags accepted before/with most subcommands.
local global_flags = {
    "-h", "--help", "-v", "--version", "-q", "--quiet", "-y", "--yes",
    "-C", "--cd", "-E", "--env", "-j", "--jobs", "-P", "--profile",
    "--verbose", "--raw", "--no-config", "--silent", "--output",
}

-- `mise run <task...>` — complete task names, repeatedly (multiple tasks).
local run_parser = clink.argmatcher():addarg({ mise_tasks }):loop()

clink.argmatcher("mise")
    :addflags(global_flags)
    :addarg({
        -- Link the run subcommands to the task-name parser so
        -- `mise run <TAB>` and `mise r <TAB>` complete task names.
        "run" .. run_parser,
        "r" .. run_parser,
        -- All other subcommands fall back to default completion.
        commands,
    })
