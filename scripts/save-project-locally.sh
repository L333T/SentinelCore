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
#   scripts/save-project-locally.sh [--dest-root <dir>] [--nav-exe <path>]
#                                   [--mmaps <dir> | --mmaps-path <path>]
#                                   [--exe-subfolder <name>] [--clean]
#   --mmaps <dir>       COPY this navmesh into <exe-subfolder>/mmaps (auto-detects SentinelNavServer/mmaps)
#   --mmaps-path <path> POINT config.toml at an existing navmesh IN PLACE (no copy) — best for a large
#                       navmesh you already have (e.g. MF_Navigation/classic_tbc). A `classic_tbc`
#                       (or `mmaps`) folder sitting under --dest-root is auto-detected and pointed at.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEST_ROOT="/mnt/c/Users/ebene/OneDrive/Desktop/MF_Navigation"
NAV_EXE=""
EXE_SUBFOLDER="navserver"
MMAPS_DIR=""            # navmesh dir to COPY into <exe-subfolder>/mmaps (auto-detected if empty)
MMAPS_PATH=""           # navmesh dir to POINT config.toml at, in place (no copy)
CLEAN=0

die() { echo "error: $*" >&2; exit 1; }
info() { echo "[save-project] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest-root) DEST_ROOT="$2"; shift 2;;
    --nav-exe) NAV_EXE="$2"; shift 2;;
    --exe-subfolder) EXE_SUBFOLDER="$2"; shift 2;;
    --mmaps) MMAPS_DIR="$2"; shift 2;;
    --mmaps-path) MMAPS_PATH="$2"; shift 2;;
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

has_tiles() { [[ -d "$1" ]] && compgen -G "$1/*.mmtile" >/dev/null 2>&1; }

# Rewrite ONLY the [navmesh.games.tbc] section's mmap_path in a config.toml to <value>. Backslashes
# are converted to forward slashes so a Windows path is a valid TOML string (Rust reads either).
set_tbc_mmap_path() {
  local config="$1" value="${2//\\//}"
  awk -v val="$value" '
    /^\[/ { intbc = ($0 ~ /^\[navmesh\.games\.tbc\]/) }
    (intbc && $0 ~ /^[[:space:]]*mmap_path[[:space:]]*=/) { print "mmap_path = \"" val "\""; next }
    { print }
  ' "$config" > "$config.tmp" && mv "$config.tmp" "$config"
}

# Resolve the navmesh into ONE of three modes:
#   MMAPS_DIR  -> COPY into <exe-subfolder>/mmaps
#   MMAPS_PATH -> POINT config.toml mmap_path at this absolute path (no copy)
#   MMAPS_REL  -> POINT config.toml mmap_path at a path relative to the exe subfolder (no copy)
MMAPS_REL=""
if [[ -z "$MMAPS_DIR" && -z "$MMAPS_PATH" ]]; then
  # Prefer an existing navmesh sitting NEXT TO the exe subfolder (e.g. MF_Navigation/classic_tbc):
  # point at it in place rather than duplicating gigabytes.
  for name in classic_tbc mmaps; do
    if has_tiles "$DEST_ROOT/$name"; then MMAPS_REL="../$name"; break; fi
  done
  # Otherwise fall back to a repo-local navmesh, which we COPY in.
  if [[ -z "$MMAPS_REL" ]]; then
    for c in "$REPO_ROOT/SentinelNavServer/mmaps" "$REPO_ROOT/mmaps"; do
      if has_tiles "$c"; then MMAPS_DIR="$c"; break; fi
    done
  fi
fi

if   [[ -n "$MMAPS_DIR"  ]]; then mmaps_desc="COPY $MMAPS_DIR ($(find "$MMAPS_DIR" -maxdepth 1 -name '*.mmtile' | wc -l) tiles) -> $EXE_SUBFOLDER/mmaps"
elif [[ -n "$MMAPS_PATH" ]]; then mmaps_desc="POINT config at $MMAPS_PATH (in place, no copy)"
elif [[ -n "$MMAPS_REL"  ]]; then mmaps_desc="POINT config at $MMAPS_REL (sibling of $EXE_SUBFOLDER, in place, no copy)"
else mmaps_desc="<none found — pathfinding disabled until you add it>"; fi
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

# Wire the navmesh according to the resolved mode (copy / point-abs / point-sibling / none).
CONFIG="$EXE_DIR/config.toml"
if [[ -n "$MMAPS_DIR" && -d "$MMAPS_DIR" ]]; then
  info "Copying navmesh → $EXE_DIR/mmaps  (this can be several GB)"
  mkdir -p "$EXE_DIR/mmaps"
  cp -r "$MMAPS_DIR/." "$EXE_DIR/mmaps/"
  MMAPS_NOTE="NAVMESH: bundled in ./mmaps (loaded automatically)."
elif [[ -n "$MMAPS_PATH" ]]; then
  info "Pointing config.toml (tbc) at $MMAPS_PATH  (in place, no copy)"
  [[ -f "$CONFIG" ]] && set_tbc_mmap_path "$CONFIG" "$MMAPS_PATH"
  MMAPS_NOTE="NAVMESH: config.toml points at $MMAPS_PATH (in place, no copy)."
elif [[ -n "$MMAPS_REL" ]]; then
  info "Pointing config.toml (tbc) at $MMAPS_REL  (sibling of $EXE_SUBFOLDER, no copy)"
  [[ -f "$CONFIG" ]] && set_tbc_mmap_path "$CONFIG" "$MMAPS_REL"
  MMAPS_NOTE="NAVMESH: config.toml points at $MMAPS_REL (the folder next to $EXE_SUBFOLDER)."
else
  mkdir -p "$EXE_DIR/mmaps"
  cat > "$EXE_DIR/mmaps/PUT_NAVMESH_HERE.txt" <<EOF
Put your CMaNGOS navmesh (*.mmap + *.mmtile) in THIS folder, OR re-run save-project-locally with
  --mmaps <dir>       to copy a navmesh in here, or
  --mmaps-path <path> to point config.toml at an existing navmesh in place (no copy).
config.toml sets mmap_path = "./mmaps" by default. Generate the navmesh with CMaNGOS MoveMapGen
(see SentinelNavServer/CLAUDE.md) - it is ~4 GB and specific to your extracted TBC client.
EOF
  MMAPS_NOTE="NAVMESH (~4 GB, client-specific, not shipped): put *.mmap/*.mmtile in ./mmaps, or point
  config.toml's [navmesh.games.tbc] mmap_path at your navmesh. Without it /health is 200 but
  pathfinding returns 404 MAP_NOT_FOUND. Generate it with CMaNGOS MoveMapGen (SentinelNavServer/CLAUDE.md)."
fi

# Launcher cd's into its own folder first, so a RELATIVE mmap_path (e.g. ../classic_tbc) resolves
# regardless of where the script is invoked from.
cat > "$EXE_DIR/start-navserver.ps1" <<'PS1'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $dir
$exe = Join-Path $dir 'NavServer.exe'
if (-not (Test-Path $exe)) { Write-Error 'NavServer.exe not found next to this script'; exit 1 }
& $exe --config (Join-Path $dir 'config.toml')
PS1

# Double-click launcher for Windows (CRLF line endings). Runs NavServer.exe with an absolute config
# path so it works no matter the working directory.
printf '@echo off\r\ncd /d "%%~dp0"\r\necho Starting SentinelNavServer on http://0.0.0.0:47110  (Ctrl+C to stop)\r\nNavServer.exe --config "%%~dp0config.toml"\r\npause\r\n' > "$EXE_DIR/Start-NavServer.bat"

cat > "$EXE_DIR/README.txt" <<EOF
SentinelNavServer (self-contained NavServer.exe) - listens on 0.0.0.0:47110 (config.toml).

$MMAPS_NOTE

Start it:  ./start-navserver.ps1   (Windows)
EOF

echo
info "Done. Project saved under: $DEST_ROOT"
info "  source tree + '$EXE_SUBFOLDER/NavServer.exe' subfolder"
