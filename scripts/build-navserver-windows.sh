#!/usr/bin/env bash
# scripts/build-navserver-windows.sh — cross-compile a self-contained Windows NavServer.exe on Linux.
#
# Uses the mingw-w64 toolchain to target x86_64-pc-windows-gnu. libstdc++ is linked statically
# (see SentinelNavServer/crates/detour-sys/build.rs) and `-static` pulls in libgcc/winpthread, so
# the resulting NavServer.exe imports only stock Windows system DLLs — no runtime DLLs to ship.
#
# Prereqs (Debian/Ubuntu):
#   sudo apt-get install -y gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 clang
#   rustup target add x86_64-pc-windows-gnu
#
# Usage:
#   scripts/build-navserver-windows.sh [--out <path/to/NavServer.exe>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAVSERVER="$REPO_ROOT/SentinelNavServer"
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 1;;
  esac
done

command -v x86_64-w64-mingw32-g++ >/dev/null || { echo "mingw-w64 g++ not found; see prereqs" >&2; exit 1; }

export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc
export CC_x86_64_pc_windows_gnu=x86_64-w64-mingw32-gcc
export CXX_x86_64_pc_windows_gnu=x86_64-w64-mingw32-g++
export AR_x86_64_pc_windows_gnu=x86_64-w64-mingw32-ar
export BINDGEN_EXTRA_CLANG_ARGS_x86_64_pc_windows_gnu="--target=x86_64-w64-mingw32 -I/usr/x86_64-w64-mingw32/include"
export RUSTFLAGS="-C link-arg=-static"

echo "[build-nav-win] cross-compiling NavServer for x86_64-pc-windows-gnu ..."
( cd "$NAVSERVER" && cargo build --release --target x86_64-pc-windows-gnu )

BUILT="$NAVSERVER/target/x86_64-pc-windows-gnu/release/sentinel-nav-server.exe"
[[ -f "$BUILT" ]] || { echo "expected exe not found: $BUILT" >&2; exit 1; }

if [[ -n "$OUT" ]]; then
  mkdir -p "$(dirname "$OUT")"
  cp "$BUILT" "$OUT"
  echo "[build-nav-win] wrote $OUT"
else
  echo "[build-nav-win] built $BUILT"
fi
