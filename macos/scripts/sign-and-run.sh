#!/usr/bin/env bash
set -euo pipefail

# Sign and run the local launch POC. This requires a real Apple signing
# identity and the Virtualization entitlement; ad-hoc signing is not release
# evidence.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${CODESIGN_IDENTITY:-}"
MANIFEST_INPUT="${1:-$ROOT/guest/manifest.json}"
if [[ -f "$MANIFEST_INPUT" ]]; then
  MANIFEST="$(cd "$(dirname "$MANIFEST_INPUT")" && pwd)/$(basename "$MANIFEST_INPUT")"
else
  MANIFEST="$(cd "$ROOT/$(dirname "$MANIFEST_INPUT")" && pwd)/$(basename "$MANIFEST_INPUT")"
fi
COW_ROOT="${COW_ROOT:-$HOME/Library/Application Support/DeskBox/cows}"

if [[ -z "$IDENTITY" ]]; then
  echo "CODESIGN_IDENTITY is required (e.g. Developer ID Application: ... )" >&2
  exit 2
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "manifest not found: $MANIFEST" >&2
  exit 2
fi

cd "$ROOT"
swift build -c release
BIN="$ROOT/.build/release/dbx-poc"
codesign --force --sign "$IDENTITY" \
  --entitlements "$ROOT/Resources/DeskBox.entitlements" \
  --options runtime "$BIN"
codesign --verify --strict --verbose=2 "$BIN"
codesign --display --entitlements :- "$BIN"

exec "$BIN" launch "$MANIFEST" --cow-root "$COW_ROOT"
