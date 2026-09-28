#!/bin/bash
set -euo pipefail
source ci/app.env
xcodebuild build -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | tail -200
