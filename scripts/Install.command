#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$SCRIPT_DIR/QuotaWarmer.app"
APP_DEST="/Applications/QuotaWarmer.app"

echo "Installing QuotaWarmer..."

if [ ! -d "$APP_SRC" ]; then
  echo "Error: QuotaWarmer.app not found next to this script."
  exit 1
fi

# Copy to /Applications (overwrite if exists)
cp -R "$APP_SRC" "$APP_DEST"

# Remove quarantine so Gatekeeper does not block the app
xattr -cr "$APP_DEST"

echo "Done. Opening QuotaWarmer..."
open "$APP_DEST"
