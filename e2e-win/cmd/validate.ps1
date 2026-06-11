<#
.SYNOPSIS
    Capture mise's cmd.exe (Clink) integration scripts and validate them.

.DESCRIPTION
    Calls `mise` directly via PowerShell's call operator (&), which invokes the
    executable through CreateProcess and therefore bypasses any cmd.exe AutoRun
    customizations (e.g. clink injection) that would otherwise pollute captured
    output. The emitted Lua is written to fixture files and handed to the pure
    Lua validator (run_tests.lua), which runs each script inside a Clink mock.

.PARAMETER MiseExe
    Path to the mise executable to test. Defaults to target/debug/mise.exe
    relative to the repo root.

.PARAMETER Lua
    Path/name of the Lua 5.4 interpreter. Defaults to "lua".

.EXAMPLE
    pwsh -NoProfile -File e2e-win/cmd/validate.ps1
#>
[CmdletBinding()]
param(
    [string]$MiseExe,
    [string]$Lua = "lua"
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\..")).Path

if (-not $MiseExe) {
    $MiseExe = Join-Path $repoRoot "target\debug\mise.exe"
}
if (-not (Test-Path $MiseExe)) {
    throw "mise executable not found at '$MiseExe'. Build it first (mise run build)."
}

$fixtures = Join-Path ([System.IO.Path]::GetTempPath()) ("mise-cmd-fixtures-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $fixtures -Force | Out-Null

try {
    # Capture activate / hook-env directly (& bypasses cmd AutoRun).
    & $MiseExe activate cmd | Out-File -FilePath (Join-Path $fixtures "activate.lua") -Encoding utf8
    & $MiseExe hook-env -s cmd 2>$null | Out-File -FilePath (Join-Path $fixtures "hook-env.lua") -Encoding utf8
    & $MiseExe completion cmd | Out-File -FilePath (Join-Path $fixtures "completion.lua") -Encoding utf8

    # Capture deactivate while presenting an activated session. `__MISE_DIFF`
    # is the marker mise uses for env::is_activated(); MISE_SHELL selects the
    # shell formatter. These are scoped to the child process only.
    $deactivate = & {
        $env:MISE_SHELL = "cmd"
        $env:__MISE_DIFF = "eAEDAAAAAAE="
        try {
            & $MiseExe deactivate 2>$null
        } finally {
            Remove-Item Env:MISE_SHELL -ErrorAction SilentlyContinue
            Remove-Item Env:__MISE_DIFF -ErrorAction SilentlyContinue
        }
    }
    $deactivate | Out-File -FilePath (Join-Path $fixtures "deactivate.lua") -Encoding utf8

    # Run the pure Lua validator against the captured fixtures.
    $runner = Join-Path $scriptDir "run_tests.lua"
    & $Lua $runner $fixtures
    $exit = $LASTEXITCODE
    return $exit
} finally {
    Remove-Item -Recurse -Force $fixtures -ErrorAction SilentlyContinue
}
