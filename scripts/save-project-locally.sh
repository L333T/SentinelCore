#!/usr/bin/env bash
# scripts/save-project-locally.sh — export the whole SentinelCore project to a local folder and
# place a runnable NavServer.exe in a subfolder.
#
# Produces, under <dest-root>:
#   <clean project source tree, from `git archive HEAD`>
#   navserver/            NavServer.exe + config.toml + start-navserver + README (the exe subfolder)
#
# The user asked for C:\Users\ebene\OneDrive\Desktop\MF_Navigation; from WSL that is
# /mnt/c/Users/ebene/OneDrive/Desktop/MF_Navigation, which is the default. Override with --dest-root.
# (The PowerShell twin defaults to the Windows path and is the native Windows path.)
#
# Usage:
#   scripts/save-project-locally.sh [--dest-root <dir>] [--nav-exe <path>] [--mmaps <dir>]
#                                   [--exe-subfolder <name>] [--clean]
#   --mmaps <dir>  navmesh to bundle into <exe-subfolder>/mmaps (auto-detects SentinelNavServer/mmaps)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEST_ROOT="/mnt/c/Users/ebene/OneDrive/Desktop/MF_Navigation"
NAV_EXE=""
EXE_SUBFOLDER="navserver"
MMAPS_DIR=""            # navmesh dir to bundle into <exe-subfolder>/mmaps (auto-detected if empty)
CLEAN=0

die() { echo "error: $*" >&2; exit 1; }
info() { echo "[save-project] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest-root) DEST_ROOT="$2"; shift 2;;
    --nav-exe) NAV_EXE="$2"; shift 2;;
    --exe-subfolder) EXE_SUBFOLDER="$2"; shift 2;;
    --mmaps) MMAPS_DIR="$2"; shift 2;;
    --clean) CLEAN=1; shift;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown option: $1";;
  esac
done

command -v git >/dev/null || die "git is required"

# Auto-detect a NavServer.exe if one wasn't supplied.
if [[ -z "$NAV_EXE" ]]; then
  for c in \
    "$REPO_ROOT/SentinelNavServer/target/x86_64-pc-windows-gnu/release/sentinel-nav-server.exe" \
    "$REPO_ROOT/SentinelNavServer/target/release/NavServer.exe"; do
    [[ -f "$c" ]] && { NAV_EXE="$c"; break; }
  done
fi

# Auto-detect a navmesh directory if one wasn't supplied (the usual generated location).
if [[ -z "$MMAPS_DIR" ]]; then
  for c in "$REPO_ROOT/SentinelNavServer/mmaps" "$REPO_ROOT/mmaps"; do
    if [[ -d "$c" ]] && compgen -G "$c/*.mmtile" >/dev/null 2>&1; then MMAPS_DIR="$c"; break; fi
  done
fi

mmaps_desc="<none found — pathfinding disabled until you add it>"
[[ -n "$MMAPS_DIR" && -d "$MMAPS_DIR" ]] && mmaps_desc="$MMAPS_DIR ($(find "$MMAPS_DIR" -maxdepth 1 -name '*.mmtile' | wc -l) tiles)"
info "Destination : $DEST_ROOT"
info "NavServer.exe: ${NAV_EXE:-<none found — build it with scripts/build-navserver-windows.sh>}"
info "mmaps navmesh: $mmaps_desc"

if [[ "$CLEAN" -eq 1 && -d "$DEST_ROOT" ]]; then
  info "Cleaning $DEST_ROOT"
  rm -rf "$DEST_ROOT"
fi
mkdir -p "$DEST_ROOT"

# 1) Export a CLEAN copy of the project (tracked files at HEAD — no target/, .git/, dist/, etc.)
info "Exporting project source (git archive HEAD) → $DEST_ROOT"
( cd "$REPO_ROOT" && git archive --format=tar HEAD ) | tar -x -C "$DEST_ROOT"

# 2) Place the runnable NavServer.exe in its subfolder, with config + launcher + mmaps note.
EXE_DIR="$DEST_ROOT/$EXE_SUBFOLDER"
mkdir -p "$EXE_DIR"
if [[ -n "$NAV_EXE" && -f "$NAV_EXE" ]]; then
  cp "$NAV_EXE" "$EXE_DIR/NavServer.exe"
  info "Placed NavServer.exe → $EXE_DIR/NavServer.exe"
else
  info "No NavServer.exe available; writing a build note instead"
  cat > "$EXE_DIR/HOW_TO_BUILD_NavServer.exe.txt" <<EOF
NavServer.exe was not bundled. Build it one of two ways:

  Windows (MSVC):   cd SentinelNavServer && cargo build --release
                    -> target\\release\\sentinel-nav-server.exe  (rename to NavServer.exe)

  Linux (mingw):    scripts/build-navserver-windows.sh --out navserver/NavServer.exe
EOF
fi
[[ -f "$REPO_ROOT/SentinelNavServer/config.toml" ]] && cp "$REPO_ROOT/SentinelNavServer/config.toml" "$EXE_DIR/config.toml"

# Bundle the navmesh (config.toml's mmap_path = "./mmaps" resolves to <exe-subfolder>/mmaps).
if [[ -n "$MMAPS_DIR" && -d "$MMAPS_DIR" ]]; then
  info "Bundling navmesh → $EXE_DIR/mmaps  (this can be several GB)"
  mkdir -p "$EXE_DIR/mmaps"
  cp -r "$MMAPS_DIR/." "$EXE_DIR/mmaps/"
else
  # Prepare the expected slot so it's unambiguous where the navmesh goes.
  mkdir -p "$EXE_DIR/mmaps"
  cat > "$EXE_DIR/mmaps/PUT_NAVMESH_HERE.txt" <<EOF
Put your CMaNGOS navmesh (*.mmap + *.mmtile) in THIS folder.

config.toml sets mmap_path = "./mmaps", so NavServer.exe loads tiles from here. Generate the
navmesh with CMaNGOS MoveMapGen (see SentinelNavServer/CLAUDE.md) — it is ~4 GB and specific to
your extracted TBC client, so it is not shipped. Re-run save-project-locally with --mmaps <dir>
(or drop the files here) to include it.
EOF
fi

cat > "$EXE_DIR/start-navserver.ps1" <<'PS1'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $dir 'NavServer.exe'
if (-not (Test-Path $exe)) { Write-Error 'NavServer.exe not found next to this script'; exit 1 }
if (-not (Test-Path (Join-Path $dir 'mmaps'))) {
    Write-Warning "No 'mmaps' folder here - pathfinding returns MAP_NOT_FOUND until you add the navmesh (see README.txt)."
}
& $exe --config (Join-Path $dir 'config.toml')
PS1

if [[ -n "$MMAPS_DIR" && -d "$MMAPS_DIR" ]]; then
  MMAPS_NOTE="NAVMESH: bundled in ./mmaps (loaded automatically)."
else
  MMAPS_NOTE="NAVMESH (~4 GB, client-specific, not shipped): put *.mmap/*.mmtile in ./mmaps.
  Without it the server starts and /health returns 200, but pathfinding returns 404 MAP_NOT_FOUND.
  Generate it with CMaNGOS MoveMapGen (see SentinelNavServer/CLAUDE.md)."
fi
cat > "$EXE_DIR/README.txt" <<EOF
SentinelNavServer (self-contained NavServer.exe) - listens on 0.0.0.0:47110 (config.toml).

$MMAPS_NOTE

Start it:  ./start-navserver.ps1   (Windows)
EOF

echo
info "Done. Project saved under: $DEST_ROOT"
info "  source tree + '$EXE_SUBFOLDER/NavServer.exe' subfolder"
