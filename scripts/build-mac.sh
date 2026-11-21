#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED_DATA="$HOME/Library/Caches/AppleProjectBuilds/book-slide/mac"
xcodebuild -project booklife.xcodeproj -scheme booklifeMac \
  -configuration Debug -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
# Local development signature, not a notarized distribution build.
codesign --force --deep --sign - "$DERIVED_DATA/Build/Products/Debug/booklife.app"
codesign --verify --deep --strict "$DERIVED_DATA/Build/Products/Debug/booklife.app"
echo "Built: $DERIVED_DATA/Build/Products/Debug/booklife.app"
