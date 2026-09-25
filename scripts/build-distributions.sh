#!/usr/bin/env bash
# scripts/build-distributions.sh — build BOTH SentinelCore distributions into subfolders.
#
# Produces, under <dest-root>:
#   thin-client/   unpacked thin-client release (+ the .zip)          — remote NavServer/QueryServer
#   standalone/    unpacked standalone release (+ the .zip)           — bundles NavServer.exe
#
# The user asked for these under C:\Users\ebene\OneDrive\Desktop\MF_Navigation; from WSL that is
# /mnt/c/Users/ebene/OneDrive/Desktop/MF_Navigation, which is this script's default. Override with
# --dest-root. (The PowerShell twin defaults to the Windows path.)
#
# Usage:
#   scripts/build-distributions.sh [--dest-root <dir>] [--version <v>]
#     [--nav-binary <path>] [--nav-binary-name <name>] [--profiles-dir <dir>]
#     [--guides-dir <dir>] [--db <world.sqlite>]
#     [--nav-url <url>] [--query-host <host>] [--query-port <port>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEST_ROOT="/mnt/c/Users/ebene/OneDrive/Desktop/MF_Navigation"
VERSION=""
NAV_BINARY=""
NAV_BINARY_NAME="NavServer.exe"
PROFILES_DIR=""
GUIDES_DIR=""
DB_PATH=""
NAV_URL="http://127.0.0.1:47110"
QUERY_HOST="127.0.0.1"
QUERY_PORT="3030"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "[build-dist] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest-root) DEST_ROOT="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    --nav-binary) NAV_BINARY="$2"; shift 2;;
    --nav-binary-name) NAV_BINARY_NAME="$2"; shift 2;;
    --profiles-dir) PROFILES_DIR="$2"; shift 2;;
    --guides-dir) GUIDES_DIR="$2"; shift 2;;
    --db) DB_PATH="$2"; shift 2;;
    --nav-url) NAV_URL="$2"; shift 2;;
    --query-host) QUERY_HOST="$2"; shift 2;;
    --query-port) QUERY_PORT="$2"; shift 2;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown option: $1";;
  esac
done

[[ -z "$VERSION" ]] && VERSION="$(cd "$REPO_ROOT" && (git describe --tags --always 2>/dev/null || git rev-parse --short HEAD 2>/dev/null) || echo '0.0.0-dev')"
command -v unzip >/dev/null || die "unzip is required"

# --- Optionally precompile profiles if none were supplied --------------------------------------
if [[ -z "$PROFILES_DIR" && -n "$GUIDES_DIR" ]]; then
  PROFILES_DIR="$(mktemp -d)"
  info "Precompiling profiles from guides -> $PROFILES_DIR"
  db_arg=(); [[ -n "$DB_PATH" ]] && db_arg=(--db "$DB_PATH")
  "$SCRIPT_DIR/precompile-profiles.sh" --out-dir "$PROFILES_DIR" --guides-dir "$GUIDES_DIR" "${db_arg[@]}"
fi
prof_arg=(); [[ -n "$PROFILES_DIR" ]] && prof_arg=(--profiles-dir "$PROFILES_DIR")

STAGE_ZIPS="$(mktemp -d)"
mkdir -p "$DEST_ROOT"

build_one() {
  local kind="$1"; shift
  info "Building $kind distribution (version $VERSION)"
  "$SCRIPT_DIR/package-release.sh" --version "$VERSION" --output-dir "$STAGE_ZIPS" \
    --nav-url "$NAV_URL" --query-host "$QUERY_HOST" --query-port "$QUERY_PORT" \
    "${prof_arg[@]}" "$@" >/dev/null
  local zip; zip="$(ls -1 "$STAGE_ZIPS"/SentinelCore-$kind-*.zip | head -1)"
  [[ -f "$zip" ]] || die "expected a $kind zip in $STAGE_ZIPS"
  local sub="$DEST_ROOT/$([[ "$kind" == "thin" ]] && echo thin-client || echo standalone)"
  rm -rf "$sub"; mkdir -p "$sub"
  unzip -q "$zip" -d "$sub"
  cp "$zip" "$sub/"
  # Flatten the single top-level release folder so install.* sits at the subfolder root.
  local inner; inner="$(find "$sub" -maxdepth 1 -type d -name 'SentinelCore-*' | head -1)"
  if [[ -n "$inner" ]]; then
    cp -r "$inner/." "$sub/"; rm -rf "$inner"
  fi
  info "  -> $sub"
}

# 1) Thin client (no NavServer bundled)
build_one thin

# 2) Standalone (bundles NavServer) — only when a binary is provided
if [[ -n "$NAV_BINARY" ]]; then
  [[ -f "$NAV_BINARY" ]] || die "--nav-binary '$NAV_BINARY' not found"
  build_one standalone --nav-binary "$NAV_BINARY" --nav-binary-name "$NAV_BINARY_NAME"
else
  info "No --nav-binary given; skipping the standalone distribution (thin-client only)."
  info "On Windows/CI pass --nav-binary path\\to\\NavServer.exe to also build standalone/."
fi

echo
info "Distributions written under: $DEST_ROOT"
ls -1 "$DEST_ROOT"
