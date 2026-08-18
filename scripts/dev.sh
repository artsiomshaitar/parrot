#!/usr/bin/env bash

set -euo pipefail

NAME="${PARROT_DEV_NAME:-parrot-dev}"
DEST="${PARROT_DEV_DIR:-$HOME/.local/bin}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT"
echo "→ building..."
swift build -c release --arch arm64

BIN=".build/arm64-apple-macosx/release/parrot"
mkdir -p "$DEST"
install -m 755 "$BIN" "$DEST/$NAME"

echo "✓ $DEST/$NAME"
echo
echo "  config:  ~/.config/$NAME/config.json   (separate from release)"
echo "  vocab:   ~/.config/parrot/vocab.txt    (shared)"
echo
echo "  quit the release copy from its menu first — two daemons fight over the hotkey."

if [ "${1:-}" = "--run" ]; then
    echo
    exec "$DEST/$NAME"
fi
