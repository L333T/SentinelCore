<#
.SYNOPSIS
    Assemble a SentinelCore THIN-CLIENT release archive.

.DESCRIPTION
    The thin client is the play-time payload only: the Lua plugin trees + compiled Runtime Profiles
    + an installer. It deliberately contains NONE of the author-time stack (Rust services, editor,
    importer, compiler, world DB, navmesh). Pathfinding is served by a hosted NavServer and NPC/item
    resolution by an (optional) hosted QueryServer - the installer points the plugins at both.

    Output: <OutputDir>/SentinelCore-thin-<Version>.zip. Mirrors scripts/package-release.sh.

.EXAMPLE
    ./package-release.ps1 -Version 0.1.0 -ProfilesDir ..\SentinelQuesting\.questing\profiles
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutputDir,
    [string]$ProfilesDir,
    [string]$NavUrl = 'http://127.0.0.1:47110',
    [string]$QueryHost = '127.0.0.1',
    [int]$QueryPort = 3030,
    [switch]$NoDebugPlugin,
    [switch]$KeepStaging
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

function Info($msg) { Write-Host "[package] $msg" }
function Die($msg) { Write-Error $msg; exit 1 }

if (-not $Version) {
    Push-Location $RepoRoot
    try {
        $Version = (git describe --tags --always 2>$null)
        if (-not $Version) { $Version = (git rev-parse --short HEAD 2>$null) }
    } catch {}
    Pop-Location
    if (-not $Version) { $Version = '0.0.0-dev' }
}
if (-not $OutputDir) { $OutputDir = Join-Path $RepoRoot 'dist' }

if (-not (Test-Path (Join-Path $RepoRoot 'sentinel'))) { Die "sentinel/ not found under repo root $RepoRoot" }
if (-not (Test-Path (Join-Path $RepoRoot 'SentinelNavClient'))) { Die "SentinelNavClient/ not found under repo root $RepoRoot" }

$PkgName = "SentinelCore-thin-$Version"
$StagingParent = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
$Staging = Join-Path $StagingParent $PkgName
New-Item -ItemType Directory -Force -Path (Join-Path $Staging 'plugins') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Staging 'profiles') | Out-Null

function Copy-Plugin($src, $dst) {
    Copy-Item -Recurse -Force $src $dst
    foreach ($d in 'tests', 'docs', '.git') {
        $p = Join-Path $dst $d
        if (Test-Path $p) { Remove-Item -Recurse -Force $p }
    }
    Get-ChildItem -Path $dst -Recurse -Filter '*.md' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

Info "Assembling $PkgName (version $Version)"
Copy-Plugin (Join-Path $RepoRoot 'sentinel') (Join-Path $Staging 'plugins/sentinel')
Copy-Plugin (Join-Path $RepoRoot 'SentinelNavClient') (Join-Path $Staging 'plugins/SentinelNavClient')
$dbgSrc = Join-Path $RepoRoot 'mcp/ext_plugin_lx_debug'
if (-not $NoDebugPlugin -and (Test-Path $dbgSrc)) {
    Copy-Plugin $dbgSrc (Join-Path $Staging 'plugins/ext_plugin_lx_debug')
}

$profileCount = 0
if ($ProfilesDir) {
    if (-not (Test-Path $ProfilesDir)) { Die "-ProfilesDir '$ProfilesDir' does not exist" }
    foreach ($f in Get-ChildItem -Path $ProfilesDir -Filter '*.json') {
        Copy-Item -Force $f.FullName (Join-Path $Staging 'profiles')
        $profileCount++
    }
}
if ($profileCount -eq 0) {
    $stub = @'
Drop compiled Runtime Profile JSON files here before (or after) installing.

Produce them from the author-time toolchain:
  cd SentinelQuesting
  cargo run -p sentinel-compiler --bin sentinel-compile -- <project>.json <name>.json

The installer copies every *.json in this folder into the Sylvannas scripts_data/ directory.
'@
    Set-Content -Path (Join-Path $Staging 'profiles/README.txt') -Value $stub -Encoding UTF8
}

Copy-Item -Force (Join-Path $ScriptDir 'install.ps1') (Join-Path $Staging 'install.ps1')
Copy-Item -Force (Join-Path $ScriptDir 'install.sh') (Join-Path $Staging 'install.sh')

$pluginNames = (Get-ChildItem -Path (Join-Path $Staging 'plugins') -Directory | ForEach-Object { '"' + $_.Name + '"' }) -join ','
$created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$manifest = @"
{
  "package": "$PkgName",
  "kind": "thin-client",
  "version": "$Version",
  "created": "$created",
  "defaults": {
    "nav_server_url": "$NavUrl",
    "query_server_host": "$QueryHost",
    "query_server_port": $QueryPort
  },
  "plugins": [$pluginNames],
  "profile_count": $profileCount,
  "notes": "Play-time payload only. NavServer (required) and QueryServer (optional) are provided by a host; the installer points the plugins at them."
}
"@
Set-Content -Path (Join-Path $Staging 'MANIFEST.json') -Value $manifest -Encoding UTF8

$readme = @"
# SentinelCore thin client ($Version)

Play-time payload for the Project Sylvannas injector: Lua plugins + compiled Runtime Profiles.
No Rust toolchain, world DB, or navmesh required - pathfinding and lookups are served remotely.

## Install (Windows)
``````powershell
./install.ps1 -NavServerUrl "$NavUrl" -QueryServerHost "$QueryHost" -QueryServerPort $QueryPort
``````

## Install (WSL / Linux shell)
``````bash
./install.sh --nav-url "$NavUrl" --query-host "$QueryHost" --query-port $QueryPort
``````

The installer auto-detects the Sylvannas ``scripts/`` folder, copies the plugins, strips the
authoring-only ``editor_ui.lua``, writes the NavServer/QueryServer config, copies profiles into
``scripts_data/``, and health-checks the servers. Reload the Sylvannas loader UI afterward.
"@
Set-Content -Path (Join-Path $Staging 'README.md') -Value $readme -Encoding UTF8

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$archive = Join-Path $OutputDir "$PkgName.zip"
if (Test-Path $archive) { Remove-Item -Force $archive }
Compress-Archive -Path $Staging -DestinationPath $archive

Info "Wrote $archive"
if ($KeepStaging) { Info "Staging kept at $Staging" } else { Remove-Item -Recurse -Force $StagingParent }
