<#
    End-to-end validation of `mise activate cmd` (cmd.exe / Clink integration).

    Rather than spin up a live cmd.exe + Clink session (which Pester cannot
    easily drive and which depends on the host's Clink install), this test
    captures the Lua that mise emits and executes it inside a Clink mock via the
    Lua validator under e2e-win/cmd/. See e2e-win/cmd/validate.ps1 and
    run_tests.lua for details.

    Requires a Lua 5.4 interpreter (matching Clink's embedded Lua). If none is
    available the test is skipped rather than failed, so CI without Lua stays
    green; install one locally with `scoop install lua` or `mise use lua@5.4`.
#>

Describe 'cmd_activate' {

    BeforeAll {
        $cmdDir = Join-Path $PSScriptRoot 'cmd'
        $script:Validate = Join-Path $cmdDir 'validate.ps1'

        # Locate mise (run.ps1 puts target/debug on PATH).
        $miseCmd = Get-Command mise -ErrorAction SilentlyContinue
        $script:MiseExe = if ($miseCmd) { $miseCmd.Source } else { $null }

        # Locate a Lua 5.4 interpreter. Prefer one already on PATH; otherwise
        # fall back to whatever mise can provide.
        $luaCmd = Get-Command lua -ErrorAction SilentlyContinue
        $script:LuaExe = if ($luaCmd) { $luaCmd.Source } else { $null }
    }

    It 'passes the cmd/Clink integration validator' {
        # Skip decisions live inside the test body: -Skip:() is evaluated at
        # discovery time, before BeforeAll runs, so $script:* vars are null then.
        if (-not $script:MiseExe) {
            Set-ItResult -Skipped -Because 'mise was not found on PATH'
            return
        }
        if (-not $script:LuaExe) {
            Set-ItResult -Skipped -Because 'no Lua 5.4 interpreter found (scoop install lua / mise use lua@5.4)'
            return
        }

        $output = & $script:Validate -MiseExe $script:MiseExe -Lua $script:LuaExe 2>&1
        $exit = $LASTEXITCODE

        # Surface the validator output in the test log for debugging.
        $output | ForEach-Object { Write-Host $_ }

        # No individual check should have failed...
        ($output | Where-Object { $_ -match 'FAIL -' }) | Should -BeNullOrEmpty
        # ...and the validator should report overall success.
        $exit | Should -Be 0
    }

    It 'reports a Lua interpreter is available' {
        if (-not $script:LuaExe) {
            Set-ItResult -Skipped -Because 'no Lua 5.4 interpreter found (scoop install lua / mise use lua@5.4)'
            return
        }
        $script:LuaExe | Should -Not -BeNullOrEmpty
    }
}
