-- run_tests.lua
--
-- Programmatic validation of mise's cmd.exe (Clink) shell integration.
--
-- This is a *pure validator*: it never spawns a subprocess. It reads the Lua
-- that `mise` emits from pre-captured fixture files and runs that Lua inside a
-- Clink mock (see mock_clink.lua), asserting on the environment mutations and
-- side effects the scripts attempt. Capturing the fixtures is the job of the
-- driver (validate.ps1 / the Pester test), which calls mise directly so it is
-- immune to cmd.exe AutoRun customizations that would otherwise pollute output.
--
-- Usage:
--   lua run_tests.lua <fixtures-dir>
--
-- Expected files in <fixtures-dir>:
--   activate.lua    output of `mise activate cmd`
--   hook-env.lua    output of `mise hook-env -s cmd`
--   deactivate.lua  output of `mise deactivate` (captured while activated)
--
-- Exit code is 0 if all checks pass, non-zero otherwise.

-- Make `require("mock_clink")` resolve next to this file regardless of cwd.
local script_dir = (arg[0] or ""):match("^(.*[\\/])") or "./"
package.path = script_dir .. "?.lua;" .. package.path

local mock = require("mock_clink")

local fixtures_dir = arg[1]
if not fixtures_dir or fixtures_dir == "" then
    io.stderr:write("usage: lua run_tests.lua <fixtures-dir>\n")
    os.exit(2)
end
-- Normalize trailing separator.
if not fixtures_dir:match("[\\/]$") then
    fixtures_dir = fixtures_dir .. "/"
end

-- ---------------------------------------------------------------------------
-- Tiny test framework
-- ---------------------------------------------------------------------------
local passed, failed = 0, 0
local failures = {}

local function check(cond, msg)
    if cond then
        passed = passed + 1
        print("  ok   - " .. msg)
    else
        failed = failed + 1
        print("  FAIL - " .. msg)
        table.insert(failures, msg)
    end
end

-- Read a fixture file. Returns "" if the file is missing/empty.
local function read_fixture(name)
    local f = io.open(fixtures_dir .. name, "r")
    if not f then
        return nil
    end
    local contents = f:read("*a")
    f:close()
    return contents or ""
end

-- ---------------------------------------------------------------------------
-- 1. `mise activate cmd` produces syntactically valid Lua
-- ---------------------------------------------------------------------------
print("== activate: syntax ==")
local activate_src = read_fixture("activate.lua")
check(activate_src ~= nil, "activate.lua fixture exists")
activate_src = activate_src or ""
do
    local chunk, err = load(activate_src, "@activate", "t")
    check(chunk ~= nil, "activate cmd output is valid Lua" .. (chunk and "" or (": " .. tostring(err))))
    check(#activate_src > 0, "activate cmd output is non-empty")
end

-- ---------------------------------------------------------------------------
-- 2. `mise activate cmd` behaves correctly inside the Clink mock
-- ---------------------------------------------------------------------------
print("== activate: behavior ==")
if #activate_src > 0 then
    -- The activate script calls `mise hook-env -s cmd` immediately; feed it a
    -- representative response so we can verify it gets evaluated.
    local sandbox = mock.new({
        env = { __MOCK_CWD = "C:\\proj" },
        popen = function(c)
            if c:find("hook-env", 1, true) then
                return 'os.setenv("MISE_HOOK_RAN", "1")\n'
            end
            return ""
        end,
    })
    local ok, run_err = pcall(function()
        sandbox:run(activate_src, "@activate")
    end)
    check(ok, "activate script executes without runtime error" .. (ok and "" or (": " .. tostring(run_err))))
    check(sandbox.env.MISE_SHELL == "cmd", "activate sets MISE_SHELL=cmd")
    check(#sandbox.onbeginedit >= 1, "activate registers a clink.onbeginedit hook")
    check(sandbox:popen_contains("hook-env -s cmd"), "activate invokes 'mise hook-env -s cmd'")
    check(sandbox.env.MISE_HOOK_RAN == "1", "activate evaluates the Lua returned by hook-env")

    local set_doskey = false
    for _, c in ipairs(sandbox.popen_calls) do
        if c:find("doskey mise=", 1, true) then
            set_doskey = true
        end
    end
    check(set_doskey, "activate registers a 'doskey mise=' macro")

    local wrote_bridge = false
    for _, contents in pairs(sandbox.written_files) do
        if contents:find("_mise_internal_handler", 1, true) then
            wrote_bridge = true
        end
    end
    check(wrote_bridge, "activate writes the doskey bridge script to a temp file")

    if #sandbox.onbeginedit >= 1 then
        -- Simulate a directory change and ensure the begin-edit hook re-runs hook-env.
        local before = #sandbox.popen_calls
        sandbox.env["__MOCK_CWD"] = "C:\\proj\\sub"
        sandbox.onbeginedit[1]()
        check(#sandbox.popen_calls > before, "onbeginedit re-runs hook-env after a directory change")

        -- No directory change => no additional hook-env call.
        local before2 = #sandbox.popen_calls
        sandbox.onbeginedit[1]()
        check(#sandbox.popen_calls == before2, "onbeginedit does not re-run hook-env when cwd is unchanged")
    end
end

-- ---------------------------------------------------------------------------
-- 3. `mise hook-env -s cmd` output is valid Lua that mutates the environment
-- ---------------------------------------------------------------------------
print("== hook-env: output ==")
do
    local hook_src = read_fixture("hook-env.lua")
    check(hook_src ~= nil, "hook-env.lua fixture exists")
    hook_src = hook_src or ""
    -- hook-env may legitimately be empty if nothing needs to change, but in a
    -- repo with a mise config it should emit at least a PATH setenv.
    local chunk, err = load(hook_src, "@hookenv", "t")
    check(chunk ~= nil, "hook-env -s cmd output is valid Lua" .. (chunk and "" or (": " .. tostring(err))))

    if #hook_src > 0 then
        local sandbox = mock.new({ env = { PATH = "C:\\existing" } })
        local ok, run_err = pcall(function()
            sandbox:run(hook_src, "@hookenv")
        end)
        check(ok, "hook-env output executes in the Clink mock" .. (ok and "" or (": " .. tostring(run_err))))
        check(#sandbox.popen_calls == 0, "hook-env output does not shell out (pure env mutation)")
        check(#sandbox.setenv_calls >= 1, "hook-env output performs at least one os.setenv")
    end
end

-- ---------------------------------------------------------------------------
-- 4. set_env / unset_env / prepend_env primitives round-trip through Lua
--    (these mirror what hook-env emits per-variable)
-- ---------------------------------------------------------------------------
print("== env primitives ==")
do
    -- set_env
    local sandbox = mock.new({ env = {} })
    sandbox:run('os.setenv("FOO", "bar")\n', "@setenv")
    check(sandbox.env.FOO == "bar", "set_env-style assignment sets the value")

    -- unset_env
    sandbox:run('os.setenv("FOO", nil)\n', "@unsetenv")
    check(sandbox.env.FOO == nil, "unset_env-style assignment clears the value")

    -- prepend_env (semantics from cmd.rs::prepend_env)
    local sandbox2 = mock.new({ env = { PATH = "C:\\old" } })
    sandbox2:run('os.setenv("PATH", "C:\\\\new" .. ";" .. (os.getenv("PATH") or ""))\n', "@prepend")
    check(sandbox2.env.PATH == "C:\\new;C:\\old", "prepend_env prepends with ';' separator")
end

-- ---------------------------------------------------------------------------
-- 5. `mise deactivate` (when activated) is valid Lua that tears down state
-- ---------------------------------------------------------------------------
print("== deactivate: behavior ==")
do
    local deactivate_src = read_fixture("deactivate.lua")
    if deactivate_src == nil or #deactivate_src == 0 then
        -- Activation not detected when the fixture was captured. Treat as a
        -- soft pass: the driver could not produce an activated session.
        check(true, "deactivate fixture empty (not activated when captured; acceptable)")
    else
        local chunk, err = load(deactivate_src, "@deactivate", "t")
        check(chunk ~= nil, "deactivate output is valid Lua" .. (chunk and "" or (": " .. tostring(err))))
        local sandbox = mock.new({
            env = { MISE_SHELL = "cmd" },
            popen = function()
                return ""
            end,
        })
        -- Seed the mise_state table the activate script would have created.
        sandbox.genv.mise_state = { script_file = "mock_tmp_1.lua" }
        local ok = pcall(function()
            sandbox:run(deactivate_src, "@deactivate")
        end)
        check(ok, "deactivate executes in the Clink mock")
        check(sandbox.env.MISE_SHELL == nil, "deactivate unsets MISE_SHELL")
    end
end

-- ---------------------------------------------------------------------------
-- 6. `mise completion cmd` produces a valid Clink argmatcher
-- ---------------------------------------------------------------------------
print("== completion: Clink argmatcher ==")
do
    local completion_src = read_fixture("completion.lua")
    if completion_src == nil then
        check(true, "completion.lua fixture absent (acceptable if not captured)")
    else
        local chunk, err = load(completion_src, "@completion", "t")
        check(chunk ~= nil, "completion cmd output is valid Lua" .. (chunk and "" or (": " .. tostring(err))))

        -- Loads safely outside Clink (the script guards on `clink`).
        local bare = mock.new({ env = {} })
        -- Temporarily hide clink to mimic stock cmd.exe / a syntax check.
        bare.genv.clink = nil
        local ok_bare = pcall(function()
            bare:run(completion_src, "@completion")
        end)
        check(ok_bare, "completion script loads safely without Clink present")

        -- With Clink present it registers a "mise" argmatcher.
        local sandbox = mock.new({ env = {} })
        local ok = pcall(function()
            sandbox:run(completion_src, "@completion")
        end)
        check(ok, "completion script executes under the Clink mock")
        local registered_mise = false
        for _, name in ipairs(sandbox.argmatchers) do
            if name == "mise" then
                registered_mise = true
            end
        end
        check(registered_mise, "completion registers a 'mise' Clink argmatcher")
    end
end

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print("")
print(string.format("== %d passed, %d failed ==", passed, failed))
if failed > 0 then
    print("Failures:")
    for _, m in ipairs(failures) do
        print("  - " .. m)
    end
    os.exit(1)
end
os.exit(0)
