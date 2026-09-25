<#
.SYNOPSIS
    Build BOTH SentinelCore distributions into subfolders of a destination root.

.DESCRIPTION
    Produces, under -DestRoot:
      thin-client\   unpacked thin-client release (+ .zip)  - remote NavServer/QueryServer
      standalone\    unpacked standalone release (+ .zip)   - bundles NavServer.exe

    Defaults -DestRoot to C:\Users\ebene\OneDrive\Desktop\MF_Navigation (the requested folder).

.EXAMPLE
    ./build-distributions.ps1 -NavBinary ..\SentinelNavServer\target\release\NavServer.exe `
                              -ProfilesDir .\profiles
#>
[CmdletBinding()]
param(
    [string]$DestRoot = 'C:\Users\ebene\OneDrive\Desktop\MF_Navigation',
    [string]$Version,
    [string]$NavBinary,
    [string]$NavBinaryName = 'NavServer.exe',
    [string]$ProfilesDir,
    [string]$NavUrl = 'http://127.0.0.1:47110',
    [string]$QueryHost = '127.0.0.1',
    [int]$QueryPort = 3030
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

function Info($m) { Write-Host "[build-dist] $m" }
function Die($m) { Write-Error $m; exit 1 }

if (-not $Version) {
    Push-Location $RepoRoot
    try { $Version = (git describe --tags --always 2>$null); if (-not $Version) { $Version = (git rev-parse --short HEAD 2>$null) } } catch {}
    Pop-Location
    if (-not $Version) { $Version = '0.0.0-dev' }
}

$stageZips = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $stageZips | Out-Null
New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null

function Build-One([string]$Kind, [string[]]$Extra) {
    Info "Building $Kind distribution (version $Version)"
    $args = @('-Version', $Version, '-OutputDir', $stageZips, '-NavUrl', $NavUrl,
              '-QueryHost', $QueryHost, '-QueryPort', $QueryPort)
    if ($ProfilesDir) { $args += @('-ProfilesDir', $ProfilesDir) }
    if ($Extra) { $args += $Extra }
    & (Join-Path $ScriptDir 'package-release.ps1') @args | Out-Null

    $zip = Get-ChildItem -Path $stageZips -Filter "SentinelCore-$Kind-*.zip" | Select-Object -First 1
    if (-not $zip) { Die "expected a $Kind zip in $stageZips" }
    $subName = if ($Kind -eq 'thin') { 'thin-client' } else { 'standalone' }
    $sub = Join-Path $DestRoot $subName
    if (Test-Path $sub) { Remove-Item -Recurse -Force $sub }
    New-Item -ItemType Directory -Force -Path $sub | Out-Null
    Expand-Archive -Path $zip.FullName -DestinationPath $sub
    Copy-Item -Force $zip.FullName $sub
    # Flatten the single top-level release folder so install.* sits at the subfolder root.
    $inner = Get-ChildItem -Path $sub -Directory | Where-Object { $_.Name -like 'SentinelCore-*' } | Select-Object -First 1
    if ($inner) {
        Copy-Item -Recurse -Force (Join-Path $inner.FullName '*') $sub
        Remove-Item -Recurse -Force $inner.FullName
    }
    Info "  -> $sub"
}

# 1) Thin client
Build-One 'thin' @()

# 2) Standalone (only when a NavServer binary is provided)
if ($NavBinary) {
    if (-not (Test-Path $NavBinary)) { Die "-NavBinary '$NavBinary' not found" }
    Build-One 'standalone' @('-NavBinary', $NavBinary, '-NavBinaryName', $NavBinaryName)
} else {
    Info "No -NavBinary given; skipping standalone. Pass -NavBinary path\to\NavServer.exe to build it."
}

Write-Host ''
Info "Distributions written under: $DestRoot"
Get-ChildItem -Path $DestRoot | Select-Object -ExpandProperty Name
