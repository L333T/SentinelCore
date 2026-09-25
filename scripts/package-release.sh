#!/usr/bin/env bash
# scripts/package-release.sh — assemble a SentinelCore THIN-CLIENT release archive.
#
# The thin client is the play-time payload only: the Lua plugin trees + compiled Runtime Profiles
# + an installer. It deliberately contains NONE of the author-time stack (Rust services, editor,
# importer, compiler, world DB, navmesh). Pathfinding is served by a hosted NavServer and NPC/item
# resolution by an (optional) hosted QueryServer — the installer points the plugins at both.
#
# Output: <output-dir>/SentinelCore-thin-<version>.zip  (a matching staging dir is left when
# --keep-staging is passed). Mirrors scripts/package-release.ps1.
#
# Usage:
#   scripts/package-release.sh [options]
#     --version <v>          Release version stamp (default: `git describe`/short SHA)
#     --output-dir <dir>     Where to write the archive (default: <repo>/dist)
#     --profiles-dir <dir>   Compiled Runtime Profile *.json to bundle (default: none → README stub)
#     --nav-url <url>        Default NavServer URL baked into MANIFEST (default: http://127.0.0.1:47110)
#     --query-host <host>    Default QueryServer host baked into MANIFEST (default: 127.0.0.1)
#     --query-port <port>    Default QueryServer port baked into MANIFEST (default: 3030)
#     --no-debug-plugin      Exclude the lx-debug plugin from the package
#     --keep-staging         Do not delete the staging directory after zipping
#     -h | --help            Show this help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION=""
OUTPUT_DIR="$REPO_ROOT/dist"
PROFILES_DIR=""
NAV_URL="http://127.0.0.1:47110"
QUERY_HOST="127.0.0.1"
QUERY_PORT="3030"
INCLUDE_DEBUG=1
KEEP_STAGING=0

die() { echo "error: $*" >&2; exit 1; }
info() { echo "[package] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2;;
    --output-dir) OUTPUT_DIR="$2"; shift 2;;
    --profiles-dir) PROFILES_DIR="$2"; shift 2;;
    --nav-url) NAV_URL="$2"; shift 2;;
    --query-host) QUERY_HOST="$2"; shift 2;;
    --query-port) QUERY_PORT="$2"; shift 2;;
    --no-debug-plugin) INCLUDE_DEBUG=0; shift;;
    --keep-staging) KEEP_STAGING=1; shift;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown option: $1";;
  esac
done

if [[ -z "$VERSION" ]]; then
  VERSION="$(cd "$REPO_ROOT" && (git describe --tags --always 2>/dev/null || git rev-parse --short HEAD 2>/dev/null) || echo "0.0.0-dev")"
fi

[[ -d "$REPO_ROOT/sentinel" ]] || die "sentinel/ not found under repo root $REPO_ROOT"
[[ -d "$REPO_ROOT/SentinelNavClient" ]] || die "SentinelNavClient/ not found under repo root $REPO_ROOT"

PKG_NAME="SentinelCore-thin-$VERSION"
STAGING_PARENT="$(mktemp -d)"
STAGING="$STAGING_PARENT/$PKG_NAME"
mkdir -p "$STAGING/plugins" "$STAGING/profiles"

# --- Copy runtime Lua trees, pruning dev-only content the injector never loads ------------------
copy_plugin() {
  local src="$1" dst="$2"
  cp -r "$src" "$dst"
  # The injector loads Lua at runtime; tests/docs/VCS metadata are pure weight in a client package.
  rm -rf "$dst/tests" "$dst/docs" "$dst/.git" 2>/dev/null || true
  find "$dst" -name '*.md' -delete 2>/dev/null || true
}

info "Assembling $PKG_NAME (version $VERSION)"
copy_plugin "$REPO_ROOT/sentinel" "$STAGING/plugins/sentinel"
copy_plugin "$REPO_ROOT/SentinelNavClient" "$STAGING/plugins/SentinelNavClient"
if [[ "$INCLUDE_DEBUG" -eq 1 && -d "$REPO_ROOT/mcp/ext_plugin_lx_debug" ]]; then
  copy_plugin "$REPO_ROOT/mcp/ext_plugin_lx_debug" "$STAGING/plugins/ext_plugin_lx_debug"
fi

# --- Bundle compiled Runtime Profiles (or leave a stub explaining where they go) ----------------
PROFILE_COUNT=0
if [[ -n "$PROFILES_DIR" ]]; then
  [[ -d "$PROFILES_DIR" ]] || die "--profiles-dir '$PROFILES_DIR' does not exist"
  shopt -s nullglob
  for f in "$PROFILES_DIR"/*.json; do
    cp "$f" "$STAGING/profiles/"; PROFILE_COUNT=$((PROFILE_COUNT+1))
  done
  shopt -u nullglob
fi
if [[ "$PROFILE_COUNT" -eq 0 ]]; then
  cat > "$STAGING/profiles/README.txt" <<EOF
Drop compiled Runtime Profile JSON files here before (or after) installing.

Produce them from the author-time toolchain:
  cd SentinelQuesting
  cargo run -p sentinel-compiler --bin sentinel-compile -- <project>.json <name>.json

The installer copies every *.json in this folder into the Sylvannas scripts_data/ directory.
EOF
fi

# --- Installer scripts travel inside the package ------------------------------------------------
cp "$SCRIPT_DIR/install.ps1" "$STAGING/install.ps1"
cp "$SCRIPT_DIR/install.sh" "$STAGING/install.sh"
chmod +x "$STAGING/install.sh"

# --- Manifest + README --------------------------------------------------------------------------
CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PLUGIN_JSON="[$(cd "$STAGING/plugins" && ls -1 | sort | sed 's/.*/"&"/' | paste -sd, -)]"
cat > "$STAGING/MANIFEST.json" <<EOF
{
  "package": "$PKG_NAME",
  "kind": "thin-client",
  "version": "$VERSION",
  "created": "$CREATED",
  "defaults": {
    "nav_server_url": "$NAV_URL",
    "query_server_host": "$QUERY_HOST",
    "query_server_port": $QUERY_PORT
  },
  "plugins": $PLUGIN_JSON,
  "profile_count": $PROFILE_COUNT,
  "notes": "Play-time payload only. NavServer (required) and QueryServer (optional) are provided by a host; the installer points the plugins at them."
}
EOF

cat > "$STAGING/README.md" <<EOF
# SentinelCore thin client ($VERSION)

Play-time payload for the Project Sylvannas injector: Lua plugins + compiled Runtime Profiles.
No Rust toolchain, world DB, or navmesh required — pathfinding and lookups are served remotely.

## Install (Windows)
\`\`\`powershell
./install.ps1 -NavServerUrl "$NAV_URL" -QueryServerHost "$QUERY_HOST" -QueryServerPort $QUERY_PORT
\`\`\`

## Install (WSL / Linux shell)
\`\`\`bash
./install.sh --nav-url "$NAV_URL" --query-host "$QUERY_HOST" --query-port $QUERY_PORT
\`\`\`

The installer auto-detects the Sylvannas \`scripts/\` folder (override with \`-ScriptsDir\` /
\`--scripts-dir\`), copies the plugins, strips the authoring-only \`editor_ui.lua\`, writes the
NavServer/QueryServer config, copies profiles into \`scripts_data/\`, and health-checks the servers.
Reload the Sylvannas loader UI afterward.
EOF

# --- Zip ----------------------------------------------------------------------------------------
mkdir -p "$OUTPUT_DIR"
ARCHIVE="$OUTPUT_DIR/$PKG_NAME.zip"
rm -f "$ARCHIVE"
( cd "$STAGING_PARENT" && zip -rq "$ARCHIVE" "$PKG_NAME" )

info "Wrote $ARCHIVE"
info "Contents:"
( cd "$STAGING_PARENT" && find "$PKG_NAME" -maxdepth 2 -printf '  %p\n' | sort )

if [[ "$KEEP_STAGING" -eq 1 ]]; then
  info "Staging kept at $STAGING"
else
  rm -rf "$STAGING_PARENT"
fi
