#!/usr/bin/env bash
# install.sh — install the SentinelCore thin client into a Project Sylvannas install.
#
# Runs from inside an unpacked release (next to plugins/ and profiles/). It:
#   1. detects the Sylvannas scripts/ (and scripts_data/) directory,
#   2. copies the Lua plugin trees in,
#   3. strips the authoring-only editor_ui.lua (play-time deploy rule),
#   4. writes the NavServer + QueryServer config the plugins read,
#   5. copies compiled profiles into scripts_data/,
#   6. health-checks the servers.
#
# Mirrors install.ps1. Intended for WSL/Linux shells; Windows users run install.ps1.
#
# Usage:
#   ./install.sh [options]
#     --scripts-dir <dir>        Sylvannas scripts/ dir (auto-detected if omitted)
#     --scripts-data-dir <dir>   Sylvannas scripts_data/ dir (derived from scripts/ if omitted)
#     --nav-url <url>            NavServer base URL (default: MANIFEST default / http://127.0.0.1:47110)
#     --query-host <host>        QueryServer host (default: MANIFEST default / 127.0.0.1)
#     --query-port <port>        QueryServer port (default: MANIFEST default / 3030)
#     --no-debug-plugin          Do not install the lx-debug plugin even if present
#     --skip-health-check        Do not probe NavServer/QueryServer /health
#     --dry-run                  Print what would happen; change nothing
#     -h | --help                Show this help
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPTS_DIR=""
SCRIPTS_DATA_DIR=""
NAV_URL=""
QUERY_HOST=""
QUERY_PORT=""
INCLUDE_DEBUG=1
SKIP_HEALTH=0
DRY_RUN=0

die() { echo "error: $*" >&2; exit 1; }
info() { echo "[install] $*"; }
run() { if [[ "$DRY_RUN" -eq 1 ]]; then echo "  DRY: $*"; else eval "$@"; fi; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scripts-dir) SCRIPTS_DIR="$2"; shift 2;;
    --scripts-data-dir) SCRIPTS_DATA_DIR="$2"; shift 2;;
    --nav-url) NAV_URL="$2"; shift 2;;
    --query-host) QUERY_HOST="$2"; shift 2;;
    --query-port) QUERY_PORT="$2"; shift 2;;
    --no-debug-plugin) INCLUDE_DEBUG=0; shift;;
    --skip-health-check) SKIP_HEALTH=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown option: $1";;
  esac
done

[[ -d "$PKG_DIR/plugins" ]] || die "plugins/ not found next to install.sh — run this from an unpacked release"

# --- Read packaged defaults from MANIFEST.json (best-effort; flags override) --------------------
manifest_get() {
  local key="$1"
  [[ -f "$PKG_DIR/MANIFEST.json" ]] || return 0
  # Minimal JSON scrape (no jq dependency): grab "key": "value" or "key": number.
  grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"?[^\",}]*\"?" "$PKG_DIR/MANIFEST.json" \
    | head -1 | sed -E "s/.*:[[:space:]]*\"?([^\"]*)\"?/\1/"
}
[[ -z "$NAV_URL" ]] && NAV_URL="$(manifest_get nav_server_url)"; [[ -z "$NAV_URL" ]] && NAV_URL="http://127.0.0.1:47110"
[[ -z "$QUERY_HOST" ]] && QUERY_HOST="$(manifest_get query_server_host)"; [[ -z "$QUERY_HOST" ]] && QUERY_HOST="127.0.0.1"
[[ -z "$QUERY_PORT" ]] && QUERY_PORT="$(manifest_get query_server_port)"; [[ -z "$QUERY_PORT" ]] && QUERY_PORT="3030"

# --- Detect the Sylvannas scripts/ directory ---------------------------------------------------
detect_scripts_dir() {
  local candidates=()
  [[ -n "${SYLVANNAS_ROOT:-}" ]] && candidates+=("$SYLVANNAS_ROOT/scripts")
  [[ -n "${SCRIPTS_DATA_PATH:-}" ]] && candidates+=("$(dirname "${SCRIPTS_DATA_PATH}")/scripts")
  # Common Windows layouts, reachable from WSL via /mnt/<drive>.
  for drive in f c d e g; do
    candidates+=("/mnt/$drive/ProjectSylvanas/scripts" "/mnt/$drive/ProjectSylvannas/scripts")
  done
  candidates+=("$HOME/ProjectSylvanas/scripts" "$HOME/.local/share/ProjectSylvanas/scripts")
  for c in "${candidates[@]}"; do
    if [[ -d "$c" ]]; then echo "$c"; return 0; fi
  done
  return 1
}

if [[ -z "$SCRIPTS_DIR" ]]; then
  SCRIPTS_DIR="$(detect_scripts_dir || true)"
  [[ -n "$SCRIPTS_DIR" ]] || die "could not auto-detect the Sylvannas scripts/ directory; pass --scripts-dir <path>"
  info "Auto-detected scripts dir: $SCRIPTS_DIR"
fi
[[ -d "$SCRIPTS_DIR" ]] || die "scripts dir does not exist: $SCRIPTS_DIR"

if [[ -z "$SCRIPTS_DATA_DIR" ]]; then
  SCRIPTS_DATA_DIR="$(dirname "$SCRIPTS_DIR")/scripts_data"
fi

info "scripts dir      : $SCRIPTS_DIR"
info "scripts_data dir : $SCRIPTS_DATA_DIR"
info "NavServer URL    : $NAV_URL"
info "QueryServer      : $QUERY_HOST:$QUERY_PORT"
[[ "$DRY_RUN" -eq 1 ]] && info "(dry run — no files will change)"

# --- 1) Copy plugin trees ----------------------------------------------------------------------
for plugin in sentinel SentinelNavClient; do
  [[ -d "$PKG_DIR/plugins/$plugin" ]] || die "package is missing plugins/$plugin"
  info "Installing plugin: $plugin"
  run "rm -rf \"$SCRIPTS_DIR/$plugin\""
  run "cp -r \"$PKG_DIR/plugins/$plugin\" \"$SCRIPTS_DIR/$plugin\""
done
if [[ "$INCLUDE_DEBUG" -eq 1 && -d "$PKG_DIR/plugins/ext_plugin_lx_debug" ]]; then
  info "Installing plugin: ext_plugin_lx_debug"
  run "rm -rf \"$SCRIPTS_DIR/ext_plugin_lx_debug\""
  run "cp -r \"$PKG_DIR/plugins/ext_plugin_lx_debug\" \"$SCRIPTS_DIR/ext_plugin_lx_debug\""
fi

# --- 2) Strip the authoring-only editor UI (play-time deploy rule) ------------------------------
EDITOR_UI="$SCRIPTS_DIR/sentinel/modules/questing/editor_ui.lua"
if [[ "$DRY_RUN" -eq 1 ]]; then
  info "Would strip editor_ui.lua if present"
elif [[ -f "$EDITOR_UI" ]]; then
  rm -f "$EDITOR_UI"; info "Stripped authoring-only editor_ui.lua"
fi

# --- 3) Write config the plugins read ----------------------------------------------------------
write_query_config() {
  local out="$SCRIPTS_DIR/sentinel/config/query_server.lua"
  info "Writing QueryServer config → $out"
  if [[ "$DRY_RUN" -eq 1 ]]; then return 0; fi
  mkdir -p "$(dirname "$out")"
  cat > "$out" <<EOF
-- sentinel/config/query_server.lua  (written by install.sh)
-- QueryServer endpoint for the in-game runtime. QueryServer is an OPTIONAL enhancement
-- (NPC spawn fallback + vendor grey-selling); the runtime degrades gracefully if it is absent.
return {
    host = "$QUERY_HOST",
    port = $QUERY_PORT,
}
EOF
}

rewrite_nav_url() {
  local out="$SCRIPTS_DIR/SentinelNavClient/config/server.lua"
  [[ -f "$out" ]] || { info "NavClient config not found ($out); skipping URL rewrite"; return 0; }
  info "Pointing NavClient at $NAV_URL → $out"
  if [[ "$DRY_RUN" -eq 1 ]]; then return 0; fi
  # Rewrite ONLY the active (non-comment) base_url assignment, preserving indentation and the
  # file's game-detection logic; the commented example line is left untouched.
  awk -v url="$NAV_URL" '
    { line=$0; t=line; sub(/^[[:space:]]+/,"",t)
      if (t ~ /^base_url[[:space:]]*=/) {
        match(line, /^[[:space:]]*/); indent=substr(line, RSTART, RLENGTH)
        print indent "base_url = \"" url "\","
      } else { print line } }
  ' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
}

write_query_config
rewrite_nav_url

# --- 4) Copy compiled profiles into scripts_data/ ----------------------------------------------
PROFILE_COUNT=0
shopt -s nullglob
PROFILES=( "$PKG_DIR"/profiles/*.json )
shopt -u nullglob
if [[ "${#PROFILES[@]}" -gt 0 ]]; then
  run "mkdir -p \"$SCRIPTS_DATA_DIR\""
  for f in "${PROFILES[@]}"; do
    info "Installing profile: $(basename "$f")"
    run "cp \"$f\" \"$SCRIPTS_DATA_DIR/\""
    PROFILE_COUNT=$((PROFILE_COUNT+1))
  done
else
  info "No compiled profiles in package (profiles/ empty) — skipping"
fi

# --- 5) Health-check the servers ---------------------------------------------------------------
health() {
  local label="$1" url="$2"
  local code
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    info "OK   $label reachable ($url → 200)"
  else
    info "WARN $label not reachable ($url → $code) — it can come up later; the runtime degrades gracefully for QueryServer"
  fi
}
if [[ "$SKIP_HEALTH" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
  health "NavServer" "${NAV_URL%/}/health"
  health "QueryServer" "http://$QUERY_HOST:$QUERY_PORT/health"
fi

echo
info "Done. Installed $PROFILE_COUNT profile(s)."
info "Next: reload the Project Sylvannas loader UI so it re-reads the files (a Lua-level reload does NOT)."
