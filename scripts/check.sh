#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CACHE_ROOT="$HOME/Library/Caches/AppleProjectBuilds/book-slide"
xcrun swift test --scratch-path "$CACHE_ROOT/swift"
node --test scripts/checks/reader-input.test.cjs scripts/checks/frame-clock.test.cjs scripts/checks/reader-scroll.test.cjs scripts/checks/reader-continuous.test.cjs
xcodebuild -project booklife.xcodeproj -scheme booklifeMac \
  -configuration Debug -derivedDataPath "$CACHE_ROOT/mac" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project booklife.xcodeproj -scheme booklifeWatch \
  -configuration Debug -destination 'generic/platform=watchOS' \
  -derivedDataPath "$CACHE_ROOT/watch" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project booklife.xcodeproj -scheme booklifePhone \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$CACHE_ROOT/iphone" CODE_SIGNING_ALLOWED=NO build
