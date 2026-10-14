#!/bin/bash
# Launch Foxlume Query with all of its data (connections, passwords, history, settings, themes) kept in one
# folder instead of ~/Library and the Keychain. Defaults to <repo>/../.userdata; set FOXLUME_DATA_DIR to change it.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DATA="${FOXLUME_DATA_DIR:-$(cd "$REPO/.." && pwd)/.userdata}"
APP="$REPO/build/Foxlume Query.app/Contents/MacOS/FoxlumeQuery"
mkdir -p "$DATA"
FOXLUME_DATA_DIR="$DATA" nohup "$APP" >/dev/null 2>&1 &
disown
echo "Foxlume Query started (data in $DATA)"
