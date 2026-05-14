#!/bin/bash
APP="/Applications/QuotaWarmer.app"
if [ ! -d "$APP" ]; then
  echo "QuotaWarmer.app not found in /Applications."
  echo "Please drag QuotaWarmer.app to the Applications folder first, then run this script."
  read -p "Press Enter to exit..."
  exit 1
fi
xattr -cr "$APP"
echo "Quarantine removed. Opening QuotaWarmer..."
open "$APP"
