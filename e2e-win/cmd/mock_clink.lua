-- mock_clink.lua
--
-- A test harness that emulates just enough of the Clink + cmd.exe Lua
-- environment to load and *behaviorally* execute the scripts produced by
-- `mise activate cmd`, `mise deactivate`, and `mise hook-env -s cmd`.
--
-- Clink injects a number of globals that don't exist in stock Lua:
--   * os.setenv(name, value)  -> mutate the cmd.exe process environment
--   * clink.onbeginedit(fn)   -> register a prompt hook
--   * (plus the usual io.popen / os.execute / os.tmpname)
--
-- Standard `lua` doesn't have these, so this module installs mocks that
-- *record* every interaction. Tests can then assert on what the generated
-- script tried to do (env mutations, doskey commands, hook invocations,
-- registered callbacks) without needing a live cmd.exe + Clink.
--
-- Usage:
--   local mock = require("mock_clink")
--   local sandbox = mock.new({
--       env = { MISE_SHELL = nil },
--       popen = function(cmd) ... return output_string end,
--   })
--   sandbox:run(generated_lua_source, "@activate")
--   assert(sandbox.env.MISE_SHELL == "cmd")

local M = {}
M.__index = M

-- Create a new sandbox.
--
-- opts:
--   env   : table of initial environment variables (defaults to {})
--   popen : function(cmd) -> string, simulates the stdout of `io.popen(cmd)`.
--           If it returns nil the command is treated as producing no output.
--   tmp   : function() -> string, simulates os.tmpname (defaults to a counter).
function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, M)

    -- Recorded state -------------------------------------------------------
    self.env = {}
    for k, v in pairs(opts.env or {}) do
        self.env[k] = v
    end
    self.setenv_calls = {} -- ordered list of { name, value }
    self.popen_calls = {} -- ordered list of command strings
    self.execute_calls = {} -- ordered list of command strings
    self.onbeginedit = {} -- registered callbacks
    self.argmatchers = {} -- names passed to clink.argmatcher
    self.prints = {} -- captured print() output
    self.written_files = {} -- path -> contents (io.open "w")
    self.removed_files = {} -- ordered list of removed paths
    self.tmp_counter = 0

    -- Hooks provided by the test ------------------------------------------
    self._popen_handler = opts.popen or function()
        return ""
    end
    self._tmp_handler = opts.tmp

    self:_build_environment()
    return self
end

-- Build the `_G`-like table the generated script will run inside.
function M:_build_environment()
    local sandbox = self
    local real_os = os
    local real_io = io

    -- Faux `os` table -----------------------------------------------------
    local mock_os = {}
    setmetatable(mock_os, { __index = real_os })

    function mock_os.setenv(name, value)
        table.insert(sandbox.setenv_calls, { name = name, value = value })
        sandbox.env[name] = value
    end

    function mock_os.getenv(name)
        return sandbox.env[name]
    end

    function mock_os.tmpname()
        if sandbox._tmp_handler then
            return sandbox._tmp_handler()
        end
        sandbox.tmp_counter = sandbox.tmp_counter + 1
        return string.format("mock_tmp_%d", sandbox.tmp_counter)
    end

    function mock_os.getcwd()
        return sandbox.env["__MOCK_CWD"] or "C:\\mock\\cwd"
    end

    function mock_os.remove(path)
        table.insert(sandbox.removed_files, path)
        sandbox.written_files[path] = nil
        return true
    end

    function mock_os.execute(cmd)
        table.insert(sandbox.execute_calls, cmd)
        return true
    end

    -- Faux `io` table -----------------------------------------------------
    local mock_io = {}
    setmetatable(mock_io, { __index = real_io })

    function mock_io.popen(cmd, mode)
        table.insert(sandbox.popen_calls, cmd)
        local output = sandbox._popen_handler(cmd) or ""
        local closed = false
        local pos = 1
        local handle = {}
        function handle:read(fmt)
            if fmt == "*a" or fmt == "a" then
                local rest = output:sub(pos)
                pos = #output + 1
                return rest
            end
            return nil
        end
        function handle:close()
            closed = true
            return true
        end
        return handle
    end

    function mock_io.open(path, mode)
        if mode and mode:find("w") then
            local buf = {}
            local file = {}
            function file:write(s)
                table.insert(buf, s)
                return file
            end
            function file:close()
                sandbox.written_files[path] = table.concat(buf)
                return true
            end
            return file
        end
        return real_io.open(path, mode)
    end

    -- Faux `clink` table --------------------------------------------------
    local mock_clink = {}
    function mock_clink.onbeginedit(fn)
        table.insert(sandbox.onbeginedit, fn)
    end
    -- Provide an argmatcher factory faithful enough to load completion scripts:
    -- chainable builder methods plus the `..` link operator Clink supports
    -- (e.g. `"run" .. parser`). Records the names passed to clink.argmatcher so
    -- tests can assert a "mise" matcher was registered.
    local matcher_mt = {}
    matcher_mt.__index = matcher_mt
    local function chain(self)
        return self
    end
    matcher_mt.addarg = chain
    matcher_mt.addflags = chain
    matcher_mt.nofiles = chain
    matcher_mt.loop = chain
    matcher_mt.setflagprefix = chain
    -- `string .. matcher` / `matcher .. matcher` -> a (new) matcher.
    matcher_mt.__concat = function(_, _)
        return setmetatable({}, matcher_mt)
    end
    function mock_clink.argmatcher(...)
        local names = { ... }
        for _, n in ipairs(names) do
            table.insert(sandbox.argmatchers, n)
        end
        return setmetatable({}, matcher_mt)
    end
    mock_clink.version_encoded = 10090000

    -- print() capture -----------------------------------------------------
    local function mock_print(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring(select(i, ...))
        end
        table.insert(sandbox.prints, table.concat(parts, "\t"))
    end

    -- Assemble the global environment the chunk will see.
    local genv = setmetatable({
        os = mock_os,
        io = mock_io,
        clink = mock_clink,
        print = mock_print,
    }, { __index = _G })
    genv._G = genv

    -- Under real Clink the *global* environment is the Clink environment, so
    -- the script's nested `load(...)` calls (e.g. in safe_load_and_run) see
    -- os.setenv et al. Stock Lua's `load` would instead default to the real
    -- _G, where os.setenv is nil. Override `load`/`loadstring` so nested
    -- chunks default to this sandbox, faithfully matching Clink semantics.
    local real_load = load
    genv.load = function(chunk, chunkname, mode, env)
        return real_load(chunk, chunkname, mode, env or genv)
    end
    if loadstring then
        genv.loadstring = function(chunk, chunkname)
            return real_load(chunk, chunkname, "t", genv)
        end
    end

    self.genv = genv
end

-- Load + execute a generated script inside the sandbox.
-- Returns true on success; raises on syntax/runtime error.
function M:run(source, chunkname)
    local chunk, err = load(source, chunkname or "@generated", "t", self.genv)
    if not chunk then
        error("syntax error: " .. tostring(err))
    end
    local ok, run_err = pcall(chunk)
    if not ok then
        error("runtime error: " .. tostring(run_err))
    end
    return true
end

-- Convenience: did the script call os.setenv(name, value)?
function M:env_was_set(name, value)
    for _, call in ipairs(self.setenv_calls) do
        if call.name == name and call.value == value then
            return true
        end
    end
    return false
end

-- Convenience: did any popen/execute command contain `needle`?
function M:popen_contains(needle)
    for _, c in ipairs(self.popen_calls) do
        if c:find(needle, 1, true) then
            return true
        end
    end
    return false
end

function M:execute_contains(needle)
    for _, c in ipairs(self.execute_calls) do
        if c:find(needle, 1, true) then
            return true
        end
    end
    return false
end

return M
