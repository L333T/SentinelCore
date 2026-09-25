<#
.SYNOPSIS
    Export the whole SentinelCore project to a local folder and place a runnable NavServer.exe in a
    subfolder.

.DESCRIPTION
    Produces, under -DestRoot (default C:\Users\ebene\OneDrive\Desktop\MF_Navigation):
      <clean project source tree, from `git archive HEAD`>
      navserver\   NavServer.exe + config.toml + start-navserver.ps1 + README (the exe subfolder)

    Run this from a clone of the repo. Mirrors save-project-locally.sh.

.EXAMPLE
    ./save-project-locally.ps1 -NavExe ..\SentinelNavServer\target\release\sentinel-nav-server.exe
#>
[CmdletBinding()]
param(
    [string]$DestRoot = 'C:\Users\ebene\OneDrive\Desktop\MF_Navigation',
    [string]$NavExe,
    [string]$ExeSubfolder = 'navserver',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

function Info($m) { Write-Host "[save-project] $m" }
function Die($m) { Write-Error $m; exit 1 }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die 'git is required' }

# Auto-detect a NavServer.exe if one wasn't supplied.
if (-not $NavExe) {
    foreach ($c in @(
        (Join-Path $RepoRoot 'SentinelNavServer/target/release/sentinel-nav-server.exe'),
        (Join-Path $RepoRoot 'SentinelNavServer/target/release/NavServer.exe'),
        (Join-Path $RepoRoot 'SentinelNavServer/target/x86_64-pc-windows-gnu/release/sentinel-nav-server.exe')
    )) { if (Test-Path $c) { $NavExe = $c; break } }
}

Info "Destination : $DestRoot"
Info "NavServer.exe: $(if ($NavExe) { $NavExe } else { '<none found - build with: cargo build --release in SentinelNavServer>' })"

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

@'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $dir 'NavServer.exe'
if (-not (Test-Path $exe)) { Write-Error 'NavServer.exe not found next to this script'; exit 1 }
if (-not (Test-Path (Join-Path $dir 'mmaps'))) {
    Write-Warning "No 'mmaps' folder here - pathfinding returns MAP_NOT_FOUND until you add the navmesh (see README.txt)."
}
& $exe --config (Join-Path $dir 'config.toml')
'@ | Set-Content -Path (Join-Path $exeDir 'start-navserver.ps1') -Encoding UTF8

@"
SentinelNavServer (self-contained NavServer.exe) - listens on 0.0.0.0:47110 (config.toml).

REQUIRED DATA (not bundled - ~4 GB, specific to your client):
  Put the CMaNGOS navmesh in a 'mmaps' folder NEXT TO NavServer.exe (config.toml sets
  mmap_path = "./mmaps"). Without it the server starts and /health returns 200, but pathfinding
  returns 404 MAP_NOT_FOUND. Generate it with CMaNGOS MoveMapGen.

Start it:  ./start-navserver.ps1
"@ | Set-Content -Path (Join-Path $exeDir 'README.txt') -Encoding UTF8

Write-Host ''
Info "Done. Project saved under: $DestRoot"
Info "  source tree + '$ExeSubfolder\NavServer.exe' subfolder"
