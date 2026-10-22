#!/bin/bash
# package-macos.sh - bundle a built tree into a ready-to-run macOS archive.
# Usage: make -f Makefile.macos && ./packaging/package-macos.sh [version]
#
# Produces packaging/dist/radmin-vpn-macos-<version>.{zip,tar.gz} and
# SHA256SUMS. The archive holds the launcher, its helpers and the built
# binaries — no compilers needed to run it. Radmin VPN itself and Wine are
# not included: run_macos.sh downloads both (pinned, sha256-checked) on first
# start.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(git -C "$DIR" describe --tags --always --dirty 2>/dev/null || echo dev)}"
NAME="radmin-vpn-macos-$VERSION"
OUT="$DIR/packaging/dist"
STAGE="$OUT/stage/$NAME"

BINS="tap_bridge rvpnnetmp.sys adapter_hook.dll rvpn_launcher.exe netsh.exe netsh64.exe drvinst.exe wow64cpu.dll"
for f in $BINS; do
    [ -f "$DIR/build/$f" ] || { echo "missing build/$f — run 'make -f Makefile.macos' first" >&2; exit 1; }
done

rm -rf "$OUT/stage" "$OUT/$NAME.zip" "$OUT/$NAME.tar.gz"
mkdir -p "$STAGE/build"
cp "$DIR/run_macos.sh" "$DIR/macos_guard.sh" "$DIR/lib.sh" "$DIR/LICENSE" "$DIR/README.md" "$STAGE/"
for f in $BINS; do cp "$DIR/build/$f" "$STAGE/build/"; done
chmod +x "$STAGE/run_macos.sh" "$STAGE/macos_guard.sh" "$STAGE/build/tap_bridge"

# Same tree twice: zip for Finder, tar.gz for the terminal (keeps modes as-is).
( cd "$OUT/stage" && zip -qry "$OUT/$NAME.zip" "$NAME" )
tar -czf "$OUT/$NAME.tar.gz" -C "$OUT/stage" "$NAME"
rm -rf "$OUT/stage"
( cd "$OUT" && shasum -a 256 "$NAME.zip" "$NAME.tar.gz" > "$NAME.SHA256SUMS" )
echo "packaged: $OUT/$NAME.zip, $NAME.tar.gz"
