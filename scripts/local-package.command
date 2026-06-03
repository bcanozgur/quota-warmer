#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/QuotaWarmerBuild"
APP_DEST="/Applications/QuotaWarmer.app"

cd "$ROOT_DIR"

echo "Building QuotaWarmer Release..."
xcodebuild -project QuotaWarmer.xcodeproj \
  -scheme QuotaWarmer \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  build

echo "Replacing existing app in /Applications..."
if [ -d "$APP_DEST" ]; then
  rm -rf "$APP_DEST"
fi

ditto "$BUILD_DIR/Build/Products/Release/QuotaWarmer.app" "$APP_DEST"
xattr -cr "$APP_DEST"

echo "Opening QuotaWarmer..."
open "$APP_DEST"
