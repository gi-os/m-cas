#!/bin/bash
set -euo pipefail
source ci/app.env
DEV=$(bash ci/sim.sh)
echo "Testing on simulator $DEV"
xcodebuild test -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -destination "id=$DEV" \
  CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -v '^$' | tail -200
