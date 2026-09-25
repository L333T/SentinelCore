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
    [string]$NavBinary,
    [string]$NavBinaryName = 'NavServer.exe',
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

# A NavServer binary switches the package from thin-client (remote services) to standalone.
if ($NavBinary) {
    if (-not (Test-Path $NavBinary)) { Die "-NavBinary '$NavBinary' does not exist" }
    $Kind = 'standalone'
} else {
    $Kind = 'thin'
}

$PkgName = "SentinelCore-$Kind-$Version"
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

# --- Standalone only: bundle the NavServer binary + config + launchers -------------------------
if ($Kind -eq 'standalone') {
    Info "Bundling standalone NavServer: $NavBinary -> navserver/$NavBinaryName"
    $navStage = Join-Path $Staging 'navserver'
    New-Item -ItemType Directory -Force -Path $navStage | Out-Null
    Copy-Item -Force $NavBinary (Join-Path $navStage $NavBinaryName)
    $navConfig = Join-Path $RepoRoot 'SentinelNavServer/config.toml'
    if (Test-Path $navConfig) { Copy-Item -Force $navConfig (Join-Path $navStage 'config.toml') }
    $startPs = @'
# Starts the bundled SentinelNavServer. Run this before playing (or let install.ps1 register it).
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $dir 'NavServer.exe'
if (-not (Test-Path $exe)) { Write-Error "NavServer.exe not found next to this script"; exit 1 }
if (-not (Test-Path (Join-Path $dir 'mmaps'))) {
    Write-Warning "No 'mmaps' folder next to NavServer.exe - pathfinding will return MAP_NOT_FOUND until you add the navmesh (see README.txt)."
}
& $exe --config (Join-Path $dir 'config.toml')
'@
    Set-Content -Path (Join-Path $navStage 'start-navserver.ps1') -Value $startPs -Encoding UTF8
    $navReadme = @"
SentinelNavServer (self-hosted) - listens on 0.0.0.0:47110 (see config.toml).

REQUIRED DATA (not bundled - it is ~4 GB and specific to your client):
  Place the CMaNGOS navmesh in a 'mmaps' folder NEXT TO $NavBinaryName
  (config.toml sets mmap_path = "./mmaps"). Generate it with CMaNGOS MoveMapGen.
  Without it the server still starts and /health returns 200, but pathfinding
  returns 404 MAP_NOT_FOUND.

Start it:  ./start-navserver.ps1   (Windows)
"@
    Set-Content -Path (Join-Path $navStage 'README.txt') -Value $navReadme -Encoding UTF8
}

Copy-Item -Force (Join-Path $ScriptDir 'install.ps1') (Join-Path $Staging 'install.ps1')
Copy-Item -Force (Join-Path $ScriptDir 'install.sh') (Join-Path $Staging 'install.sh')

$pluginNames = (Get-ChildItem -Path (Join-Path $Staging 'plugins') -Directory | ForEach-Object { '"' + $_.Name + '"' }) -join ','
$created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
if ($Kind -eq 'standalone') {
    $kindLabel = 'standalone'
    $navJson = "{ ""bundled"": true, ""binary"": ""$NavBinaryName"", ""needs_mmaps"": true }"
    $notes = 'Self-hosted: bundles NavServer (needs a local mmaps navmesh) plus the Lua payload and profiles. The installer deploys NavServer and points the plugins at 127.0.0.1.'
} else {
    $kindLabel = 'thin-client'
    $navJson = '{ "bundled": false }'
    $notes = 'Play-time payload only. NavServer (required) and QueryServer (optional) are provided by a host; the installer points the plugins at them.'
}
$manifest = @"
{
  "package": "$PkgName",
  "kind": "$kindLabel",
  "version": "$Version",
  "created": "$created",
  "defaults": {
    "nav_server_url": "$NavUrl",
    "query_server_host": "$QueryHost",
    "query_server_port": $QueryPort
  },
  "navserver": $navJson,
  "plugins": [$pluginNames],
  "profile_count": $profileCount,
  "notes": "$notes"
}
"@
Set-Content -Path (Join-Path $Staging 'MANIFEST.json') -Value $manifest -Encoding UTF8

if ($Kind -eq 'standalone') {
$readme = @"
# SentinelCore standalone ($Version)

Self-hosted, offline-capable payload: Lua plugins, compiled Runtime Profiles, AND a bundled
SentinelNavServer ($NavBinaryName). Add a local ``mmaps`` navmesh next to the binary
(see ``navserver/README.txt``); no remote services required.

## Install (Windows)
``````powershell
./install.ps1 -InstallNavServer
``````

## Install (WSL / Linux shell)
``````bash
./install.sh --install-navserver
``````

The installer deploys the plugins + NavServer, writes localhost config, copies profiles, and
health-checks. Start the NavServer (``navserver/start-navserver.ps1``) and reload the loader UI.
"@
} else {
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
}
Set-Content -Path (Join-Path $Staging 'README.md') -Value $readme -Encoding UTF8

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$archive = Join-Path $OutputDir "$PkgName.zip"
if (Test-Path $archive) { Remove-Item -Force $archive }
Compress-Archive -Path $Staging -DestinationPath $archive

Info "Wrote $archive"
if ($KeepStaging) { Info "Staging kept at $Staging" } else { Remove-Item -Recurse -Force $StagingParent }
