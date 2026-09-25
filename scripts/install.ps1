<#
.SYNOPSIS
    Install the SentinelCore thin client into a Project Sylvannas installation.

.DESCRIPTION
    Runs from inside an unpacked release (next to plugins/ and profiles/). It:
      1. detects the Sylvannas scripts/ (and scripts_data/) directory,
      2. copies the Lua plugin trees in,
      3. strips the authoring-only editor_ui.lua (play-time deploy rule),
      4. writes the NavServer + QueryServer config the plugins read,
      5. copies compiled profiles into scripts_data/,
      6. health-checks the servers.

    Mirrors install.sh. This is the primary path for Windows users.

.EXAMPLE
    ./install.ps1 -NavServerUrl "http://127.0.0.1:47110" -QueryServerHost "127.0.0.1" -QueryServerPort 3030
#>
[CmdletBinding()]
param(
    [string]$ScriptsDir,
    [string]$ScriptsDataDir,
    [string]$NavServerUrl,
    [string]$QueryServerHost,
    [int]$QueryServerPort = 0,
    [switch]$NoDebugPlugin,
    [switch]$SkipHealthCheck,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$PkgDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Info($msg) { Write-Host "[install] $msg" }
function Die($msg) { Write-Error $msg; exit 1 }
function Do-Action($desc, [scriptblock]$action) {
    if ($DryRun) { Write-Host "  DRY: $desc" } else { & $action }
}

if (-not (Test-Path (Join-Path $PkgDir 'plugins'))) {
    Die "plugins/ not found next to install.ps1 - run this from an unpacked release"
}

# --- Read packaged defaults from MANIFEST.json (params override) --------------------------------
$manifest = $null
$manifestPath = Join-Path $PkgDir 'MANIFEST.json'
if (Test-Path $manifestPath) {
    try { $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json } catch { $manifest = $null }
}
if (-not $NavServerUrl) {
    $NavServerUrl = if ($manifest -and $manifest.defaults.nav_server_url) { $manifest.defaults.nav_server_url } else { 'http://127.0.0.1:47110' }
}
if (-not $QueryServerHost) {
    $QueryServerHost = if ($manifest -and $manifest.defaults.query_server_host) { $manifest.defaults.query_server_host } else { '127.0.0.1' }
}
if ($QueryServerPort -le 0) {
    $QueryServerPort = if ($manifest -and $manifest.defaults.query_server_port) { [int]$manifest.defaults.query_server_port } else { 3030 }
}

# --- Detect the Sylvannas scripts/ directory ---------------------------------------------------
function Find-ScriptsDir {
    $candidates = @()
    if ($env:SYLVANNAS_ROOT) { $candidates += (Join-Path $env:SYLVANNAS_ROOT 'scripts') }
    if ($env:SCRIPTS_DATA_PATH) { $candidates += (Join-Path (Split-Path -Parent $env:SCRIPTS_DATA_PATH) 'scripts') }
    foreach ($drive in 'F','C','D','E','G') {
        $candidates += "${drive}:\ProjectSylvanas\scripts"
        $candidates += "${drive}:\ProjectSylvannas\scripts"
    }
    $candidates += (Join-Path $env:USERPROFILE 'ProjectSylvanas\scripts')
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

if (-not $ScriptsDir) {
    $ScriptsDir = Find-ScriptsDir
    if (-not $ScriptsDir) { Die "could not auto-detect the Sylvannas scripts/ directory; pass -ScriptsDir <path>" }
    Info "Auto-detected scripts dir: $ScriptsDir"
}
if (-not (Test-Path $ScriptsDir)) { Die "scripts dir does not exist: $ScriptsDir" }
if (-not $ScriptsDataDir) { $ScriptsDataDir = Join-Path (Split-Path -Parent $ScriptsDir) 'scripts_data' }

Info "scripts dir      : $ScriptsDir"
Info "scripts_data dir : $ScriptsDataDir"
Info "NavServer URL    : $NavServerUrl"
Info "QueryServer      : ${QueryServerHost}:${QueryServerPort}"
if ($DryRun) { Info "(dry run - no files will change)" }

# --- 1) Copy plugin trees ----------------------------------------------------------------------
$plugins = @('sentinel', 'SentinelNavClient')
foreach ($plugin in $plugins) {
    $src = Join-Path $PkgDir "plugins/$plugin"
    if (-not (Test-Path $src)) { Die "package is missing plugins/$plugin" }
    $dst = Join-Path $ScriptsDir $plugin
    Info "Installing plugin: $plugin"
    Do-Action "remove + copy $plugin" {
        if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
        Copy-Item -Recurse -Force $src $dst
    }
}
$dbgSrc = Join-Path $PkgDir 'plugins/ext_plugin_lx_debug'
if (-not $NoDebugPlugin -and (Test-Path $dbgSrc)) {
    $dbgDst = Join-Path $ScriptsDir 'ext_plugin_lx_debug'
    Info "Installing plugin: ext_plugin_lx_debug"
    Do-Action "remove + copy ext_plugin_lx_debug" {
        if (Test-Path $dbgDst) { Remove-Item -Recurse -Force $dbgDst }
        Copy-Item -Recurse -Force $dbgSrc $dbgDst
    }
}

# --- 2) Strip the authoring-only editor UI (play-time deploy rule) ------------------------------
$editorUi = Join-Path $ScriptsDir 'sentinel/modules/questing/editor_ui.lua'
if ($DryRun) {
    Info "Would strip editor_ui.lua if present"
} elseif (Test-Path $editorUi) {
    Remove-Item -Force $editorUi
    Info "Stripped authoring-only editor_ui.lua"
}

# --- 3) Write config the plugins read ----------------------------------------------------------
$queryCfgPath = Join-Path $ScriptsDir 'sentinel/config/query_server.lua'
Info "Writing QueryServer config -> $queryCfgPath"
if (-not $DryRun) {
    $queryCfgDir = Split-Path -Parent $queryCfgPath
    if (-not (Test-Path $queryCfgDir)) { New-Item -ItemType Directory -Force -Path $queryCfgDir | Out-Null }
    $queryCfg = @"
-- sentinel/config/query_server.lua  (written by install.ps1)
-- QueryServer endpoint for the in-game runtime. QueryServer is an OPTIONAL enhancement
-- (NPC spawn fallback + vendor grey-selling); the runtime degrades gracefully if it is absent.
return {
    host = "$QueryServerHost",
    port = $QueryServerPort,
}
"@
    Set-Content -Path $queryCfgPath -Value $queryCfg -Encoding UTF8
}

$navCfgPath = Join-Path $ScriptsDir 'SentinelNavClient/config/server.lua'
if (Test-Path $navCfgPath) {
    Info "Pointing NavClient at $NavServerUrl -> $navCfgPath"
    if (-not $DryRun) {
        # Rewrite ONLY the active (non-comment) base_url assignment, preserving the file's
        # game-detection logic; the commented example line is left untouched.
        $lines = Get-Content $navCfgPath
        $out = foreach ($line in $lines) {
            $trimmed = $line.TrimStart()
            if ($trimmed -match '^base_url\s*=') {
                $indent = $line.Substring(0, $line.Length - $trimmed.Length)
                "$indent" + 'base_url = "' + $NavServerUrl + '",'
            } else { $line }
        }
        Set-Content -Path $navCfgPath -Value $out -Encoding UTF8
    }
} else {
    Info "NavClient config not found ($navCfgPath); skipping URL rewrite"
}

# --- 4) Copy compiled profiles into scripts_data/ ----------------------------------------------
$profileCount = 0
$profiles = @(Get-ChildItem -Path (Join-Path $PkgDir 'profiles') -Filter '*.json' -ErrorAction SilentlyContinue)
if ($profiles.Count -gt 0) {
    Do-Action "ensure scripts_data dir" {
        if (-not (Test-Path $ScriptsDataDir)) { New-Item -ItemType Directory -Force -Path $ScriptsDataDir | Out-Null }
    }
    foreach ($p in $profiles) {
        Info "Installing profile: $($p.Name)"
        Do-Action "copy $($p.Name)" { Copy-Item -Force $p.FullName (Join-Path $ScriptsDataDir $p.Name) }
        $profileCount++
    }
} else {
    Info "No compiled profiles in package (profiles/ empty) - skipping"
}

# --- 5) Health-check the servers ---------------------------------------------------------------
function Test-Health($label, $url) {
    try {
        $resp = Invoke-WebRequest -Uri $url -TimeoutSec 5 -UseBasicParsing
        if ($resp.StatusCode -eq 200) { Info "OK   $label reachable ($url -> 200)"; return }
    } catch {}
    Info "WARN $label not reachable ($url) - it can come up later; the runtime degrades gracefully for QueryServer"
}
if (-not $SkipHealthCheck -and -not $DryRun) {
    Test-Health "NavServer" ("{0}/health" -f $NavServerUrl.TrimEnd('/'))
    Test-Health "QueryServer" ("http://{0}:{1}/health" -f $QueryServerHost, $QueryServerPort)
}

Write-Host ''
Info "Done. Installed $profileCount profile(s)."
Info "Next: reload the Project Sylvannas loader UI so it re-reads the files (a Lua-level reload does NOT)."
