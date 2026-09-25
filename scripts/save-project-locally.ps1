<#
.SYNOPSIS
    Export the whole SentinelCore project to a local folder and place a runnable NavServer.exe in a
    subfolder.

.DESCRIPTION
    Produces, under -DestRoot (default C:\Users\ebene\OneDrive\Desktop\MF_Navigation):
      <clean project source tree, from `git archive HEAD`>
      navserver\   NavServer.exe + config.toml + start-navserver.ps1 + README (the exe subfolder)

    Navmesh options (mutually exclusive):
      -Mmaps <dir>       COPY a navmesh into navserver\mmaps.
      -MmapsPath <path>  POINT config.toml at an existing navmesh IN PLACE (no copy) - best for a
                         large navmesh you already have. A `classic_tbc` (or `mmaps`) folder sitting
                         under -DestRoot is auto-detected and pointed at (as ..\classic_tbc).

    Run this from a clone of the repo. Mirrors save-project-locally.sh.

.EXAMPLE
    # Your mmaps are at C:\Users\ebene\OneDrive\Desktop\MF_Navigation\classic_tbc:
    ./save-project-locally.ps1 -MmapsPath 'C:\Users\ebene\OneDrive\Desktop\MF_Navigation\classic_tbc'
#>
[CmdletBinding()]
param(
    [string]$DestRoot = 'C:\Users\ebene\OneDrive\Desktop\MF_Navigation',
    [string]$NavExe,
    [string]$Mmaps,
    [string]$MmapsPath,
    [string]$ExeSubfolder = 'navserver',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

function Info($m) { Write-Host "[save-project] $m" }
function Die($m) { Write-Error $m; exit 1 }

# Rewrite ONLY the [navmesh.games.tbc] section's mmap_path in a config.toml to $value. Backslashes
# become forward slashes so a Windows path is a valid TOML string (Rust reads either).
function Set-TbcMmapPath([string]$config, [string]$value) {
    $val = $value -replace '\\', '/'
    $inTbc = $false
    $out = foreach ($line in (Get-Content $config)) {
        if ($line -match '^\[') { $inTbc = ($line -match '^\[navmesh\.games\.tbc\]') }
        if ($inTbc -and $line -match '^\s*mmap_path\s*=') { 'mmap_path = "' + $val + '"' } else { $line }
    }
    Set-Content -Path $config -Value $out -Encoding UTF8
}
function Test-HasTiles([string]$dir) {
    return (Test-Path $dir) -and (Get-ChildItem -Path $dir -Filter '*.mmtile' -ErrorAction SilentlyContinue | Select-Object -First 1)
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die 'git is required' }

# Auto-detect a NavServer.exe if one wasn't supplied.
if (-not $NavExe) {
    foreach ($c in @(
        (Join-Path $RepoRoot 'SentinelNavServer/target/release/sentinel-nav-server.exe'),
        (Join-Path $RepoRoot 'SentinelNavServer/target/release/NavServer.exe'),
        (Join-Path $RepoRoot 'SentinelNavServer/target/x86_64-pc-windows-gnu/release/sentinel-nav-server.exe')
    )) { if (Test-Path $c) { $NavExe = $c; break } }
}

# Resolve the navmesh into ONE of three modes: copy ($Mmaps), point-absolute ($MmapsPath), or
# point-relative to a sibling of the exe subfolder ($MmapsRel).
$MmapsRel = ''
if (-not $Mmaps -and -not $MmapsPath) {
    # Prefer an existing navmesh next to the exe subfolder (e.g. MF_Navigation\classic_tbc): point
    # at it in place rather than duplicating gigabytes.
    foreach ($name in @('classic_tbc', 'mmaps')) {
        if (Test-HasTiles (Join-Path $DestRoot $name)) { $MmapsRel = "../$name"; break }
    }
    if (-not $MmapsRel) {
        foreach ($c in @((Join-Path $RepoRoot 'SentinelNavServer/mmaps'), (Join-Path $RepoRoot 'mmaps'))) {
            if (Test-HasTiles $c) { $Mmaps = $c; break }
        }
    }
}

$mmapsDesc = if ($Mmaps) { "COPY $Mmaps -> $ExeSubfolder\mmaps" }
    elseif ($MmapsPath) { "POINT config at $MmapsPath (in place, no copy)" }
    elseif ($MmapsRel) { "POINT config at $MmapsRel (sibling of $ExeSubfolder, no copy)" }
    else { '<none found - pathfinding disabled until you add it>' }
Info "Destination : $DestRoot"
Info "NavServer.exe: $(if ($NavExe) { $NavExe } else { '<none found - build with: cargo build --release in SentinelNavServer>' })"
Info "mmaps navmesh: $mmapsDesc"

if ($Clean -and (Test-Path $DestRoot)) { Info "Cleaning $DestRoot"; Remove-Item -Recurse -Force $DestRoot }
New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null

# 1) Export a CLEAN copy of the project (tracked files at HEAD - no target/, .git/, dist/).
Info "Exporting project source (git archive HEAD) -> $DestRoot"
$tmpZip = Join-Path ([System.IO.Path]::GetTempPath()) ("sentinelcore-" + [System.IO.Path]::GetRandomFileName() + '.zip')
Push-Location $RepoRoot
try { git archive --format=zip -o $tmpZip HEAD } finally { Pop-Location }
Expand-Archive -Path $tmpZip -DestinationPath $DestRoot -Force
Remove-Item -Force $tmpZip

# 2) Place the runnable NavServer.exe in its subfolder, with config + launcher + mmaps note.
$exeDir = Join-Path $DestRoot $ExeSubfolder
New-Item -ItemType Directory -Force -Path $exeDir | Out-Null
if ($NavExe -and (Test-Path $NavExe)) {
    Copy-Item -Force $NavExe (Join-Path $exeDir 'NavServer.exe')
    Info "Placed NavServer.exe -> $(Join-Path $exeDir 'NavServer.exe')"
} else {
    Info 'No NavServer.exe available; writing a build note instead'
    @"
NavServer.exe was not bundled. Build it:
  cd SentinelNavServer && cargo build --release
  -> target\release\sentinel-nav-server.exe  (rename to NavServer.exe and drop it here)
"@ | Set-Content -Path (Join-Path $exeDir 'HOW_TO_BUILD_NavServer.exe.txt') -Encoding UTF8
}
$navConfig = Join-Path $RepoRoot 'SentinelNavServer/config.toml'
if (Test-Path $navConfig) { Copy-Item -Force $navConfig (Join-Path $exeDir 'config.toml') }

# Wire the navmesh according to the resolved mode (copy / point-abs / point-sibling / none).
$config = Join-Path $exeDir 'config.toml'
if ($Mmaps -and (Test-Path $Mmaps)) {
    $mmapsDst = Join-Path $exeDir 'mmaps'
    New-Item -ItemType Directory -Force -Path $mmapsDst | Out-Null
    Info "Copying navmesh -> $mmapsDst  (this can be several GB)"
    Copy-Item -Recurse -Force (Join-Path $Mmaps '*') $mmapsDst
    $mmapsNote = 'NAVMESH: bundled in .\mmaps (loaded automatically).'
} elseif ($MmapsPath) {
    Info "Pointing config.toml (tbc) at $MmapsPath  (in place, no copy)"
    if (Test-Path $config) { Set-TbcMmapPath $config $MmapsPath }
    $mmapsNote = "NAVMESH: config.toml points at $MmapsPath (in place, no copy)."
} elseif ($MmapsRel) {
    Info "Pointing config.toml (tbc) at $MmapsRel  (sibling of $ExeSubfolder, no copy)"
    if (Test-Path $config) { Set-TbcMmapPath $config $MmapsRel }
    $mmapsNote = "NAVMESH: config.toml points at $MmapsRel (the folder next to $ExeSubfolder)."
} else {
    $mmapsDst = Join-Path $exeDir 'mmaps'
    New-Item -ItemType Directory -Force -Path $mmapsDst | Out-Null
    @"
Put your CMaNGOS navmesh (*.mmap + *.mmtile) in THIS folder, OR re-run save-project-locally with
  -Mmaps <dir>       to copy a navmesh in here, or
  -MmapsPath <path>  to point config.toml at an existing navmesh in place (no copy).
config.toml sets mmap_path = "./mmaps" by default. Generate the navmesh with CMaNGOS MoveMapGen
(see SentinelNavServer/CLAUDE.md) - it is ~4 GB and specific to your extracted TBC client.
"@ | Set-Content -Path (Join-Path $mmapsDst 'PUT_NAVMESH_HERE.txt') -Encoding UTF8
    $mmapsNote = "NAVMESH (~4 GB, client-specific): put *.mmap/*.mmtile in .\mmaps, or point config.toml's [navmesh.games.tbc] mmap_path at your navmesh. Without it /health is 200 but pathfinding is 404 MAP_NOT_FOUND."
}

# Launcher cd's into its own folder first, so a RELATIVE mmap_path (e.g. ../classic_tbc) resolves.
@'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $dir
$exe = Join-Path $dir 'NavServer.exe'
if (-not (Test-Path $exe)) { Write-Error 'NavServer.exe not found next to this script'; exit 1 }
& $exe --config (Join-Path $dir 'config.toml')
'@ | Set-Content -Path (Join-Path $exeDir 'start-navserver.ps1') -Encoding UTF8

# Double-click launcher for Windows. Runs NavServer.exe with an absolute config path.
$bat = "@echo off`r`ncd /d `"%~dp0`"`r`necho Starting SentinelNavServer on http://0.0.0.0:47110  (Ctrl+C to stop)`r`nNavServer.exe --config `"%~dp0config.toml`"`r`npause`r`n"
Set-Content -Path (Join-Path $exeDir 'Start-NavServer.bat') -Value $bat -NoNewline -Encoding ascii
@"
SentinelNavServer (self-contained NavServer.exe) - listens on 0.0.0.0:47110 (config.toml).

$mmapsNote

Start it:  .\start-navserver.ps1
"@ | Set-Content -Path (Join-Path $exeDir 'README.txt') -Encoding UTF8

Write-Host ''
Info "Done. Project saved under: $DestRoot"
Info "  source tree + '$ExeSubfolder\NavServer.exe' subfolder"
