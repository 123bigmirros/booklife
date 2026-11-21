#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SHARED_SIM="$HOME/.local/bin/shared-apple-sim"
if [[ "${SHARED_APPLE_SIM_KIND:-}" != ipad ]]; then
  if [[ -x "$SHARED_SIM" ]]; then
    exec "$SHARED_SIM" run --project book-slide ipad -- bash "$0" "$@"
  elif [[ "${CI:-false}" == true && -n "${BOOKSLIDE_IPAD_SIMULATOR_ID:-}" ]]; then
    # Standalone CI runners select one of their existing iPads; no workstation IDs in source.
    export SHARED_APPLE_SIMULATOR_ID="$BOOKSLIDE_IPAD_SIMULATOR_ID"
    export SHARED_APPLE_SIMULATOR_DESTINATION="platform=iOS Simulator,id=$BOOKSLIDE_IPAD_SIMULATOR_ID"
    export SHARED_APPLE_DERIVED_DATA="$HOME/Library/Caches/AppleProjectBuilds/book-slide/ipad"
  else
    echo 'This wrapper needs the shared-apple-sim workstation tool or a CI iPad destination. For a standalone checkout, use the iPad test schemes in Xcode (see scripts/README.md).' >&2
    exit 1
  fi
fi
DERIVED_DATA="$SHARED_APPLE_DERIVED_DATA"

# Retain reports in Logs/Test, but release simulator binaries even if tests fail.
# Set BOOKSLIDE_KEEP_SIMULATOR_BUILDS=1 when debugging with the built app.
cleanup() {
  status=$?
  if [[ "${BOOKSLIDE_KEEP_SIMULATOR_BUILDS:-0}" != 1 ]]; then
    python3 scripts/clean-simulator-builds.py --derived-data "$DERIVED_DATA" --apply || {
      echo "Simulator cleanup failed; run python3 scripts/clean-simulator-builds.py --apply" >&2
      if [[ "$status" == 0 ]]; then status=1; fi
    }
  fi
  exit "$status"
}
trap cleanup EXIT

for scheme in booklifePencilTests booklifeUITests; do
  xcodebuild -project booklife.xcodeproj -scheme "$scheme" \
    -destination "$SHARED_APPLE_SIMULATOR_DESTINATION" \
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
    -derivedDataPath "$DERIVED_DATA" \
    ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test "$@"
done
