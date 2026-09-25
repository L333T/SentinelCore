#!/usr/bin/env bash
# scripts/precompile-profiles.sh — produce compiled Runtime Profile JSONs for a release.
#
# Two modes:
#   --projects-dir DIR   compile every *.json project already in DIR (deterministic, fast), OR
#   --guides-dir DIR     import RestedXP guides -> projects first, then compile.
#
# Reference resolution:
#   Pass --db <tbcmangos.sqlite> to resolve NPC/quest/item references against the real world DB.
#   With no --db, a throwaway empty SQLite is used so the import still runs FAST (the importer
#   degrades unresolved references to diagnostics instead of retrying a dead connection) and the
#   compiler still emits structurally valid profiles — handy for CI without the proprietary DB.
#
# Usage:
#   scripts/precompile-profiles.sh --out-dir <dir> [--projects-dir <dir> | --guides-dir <dir>]
#                                  [--db <path>] [--query-port <port>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
QUESTING="$REPO_ROOT/SentinelQuesting"
QUERYSERVER="$REPO_ROOT/SentinelQueryServer"

OUT_DIR=""
PROJECTS_DIR=""
GUIDES_DIR=""
DB_PATH=""
QUERY_PORT="3030"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "[precompile] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir) OUT_DIR="$2"; shift 2;;
    --projects-dir) PROJECTS_DIR="$2"; shift 2;;
    --guides-dir) GUIDES_DIR="$2"; shift 2;;
    --db) DB_PATH="$2"; shift 2;;
    --query-port) QUERY_PORT="$2"; shift 2;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown option: $1";;
  esac
done

[[ -n "$OUT_DIR" ]] || die "--out-dir is required"
mkdir -p "$OUT_DIR"

info "Building editor + compiler (release)"
( cd "$QUESTING" && cargo build --release -p sentinel-editor -p sentinel-compiler >/dev/null )
COMPILE_BIN="$QUESTING/target/release/sentinel-compile"
IMPORT_BIN="$QUESTING/target/release/import-guides"
[[ -x "$COMPILE_BIN" ]] || die "compiler binary missing: $COMPILE_BIN"

QS_PID=""
cleanup() { [[ -n "$QS_PID" ]] && kill "$QS_PID" 2>/dev/null || true; }
trap cleanup EXIT

# --- Resolve a projects directory (import guides if only guides were given) ---------------------
if [[ -z "$PROJECTS_DIR" ]]; then
  [[ -n "$GUIDES_DIR" ]] || die "pass either --projects-dir or --guides-dir"
  [[ -d "$GUIDES_DIR" ]] || die "--guides-dir '$GUIDES_DIR' does not exist"
  PROJECTS_DIR="$(mktemp -d)"

  # A live QueryServer keeps import fast (resolved OR fast-404); build a throwaway DB if none given.
  if [[ -z "$DB_PATH" ]]; then
    DB_PATH="$(mktemp -d)/empty.sqlite"
    sqlite3 "$DB_PATH" "VACUUM;" 2>/dev/null || : > "$DB_PATH"
    info "No --db given; using a throwaway empty DB (profiles will be structural, refs unresolved)"
  else
    info "Resolving references against $DB_PATH"
  fi

  info "Building + starting QueryServer on 127.0.0.1:$QUERY_PORT"
  ( cd "$QUERYSERVER" && cargo build --release >/dev/null )
  SENTINEL_DB="$DB_PATH" SENTINEL_QUERY_PORT="$QUERY_PORT" \
    "$QUERYSERVER/target/release/sentinel-query-server" >/tmp/precompile_qs.log 2>&1 &
  QS_PID=$!
  for _ in $(seq 1 30); do
    curl -s -o /dev/null "http://127.0.0.1:$QUERY_PORT/health" && break || sleep 0.5
  done

  info "Importing guides from $GUIDES_DIR"
  SENTINEL_QUERY_URL="http://127.0.0.1:$QUERY_PORT" \
    "$IMPORT_BIN" "$GUIDES_DIR" "$PROJECTS_DIR" >/tmp/precompile_import.log 2>&1 \
    || info "import returned non-zero (partial corpus is OK) — see /tmp/precompile_import.log"
fi

# --- Compile every project (skip the importer's coverage report) -------------------------------
COUNT=0
shopt -s nullglob
for proj in "$PROJECTS_DIR"/*.json; do
  base="$(basename "$proj")"
  [[ "$base" == "coverage_report.json" ]] && continue
  stem="${base%.json}"
  out="$OUT_DIR/${stem}.profile.json"
  if "$COMPILE_BIN" "$proj" "$out" >/dev/null 2>&1; then
    COUNT=$((COUNT+1))
    info "compiled: $base -> ${stem}.profile.json"
  else
    info "SKIP (compile failed): $base"
  fi
done
shopt -u nullglob

info "Done. Wrote $COUNT profile(s) to $OUT_DIR"
[[ "$COUNT" -gt 0 ]] || die "no profiles were produced"
