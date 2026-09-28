#!/bin/bash
# Newest non-beta Xcode on the runner.
set -euo pipefail
X=$(ls -d /Applications/Xcode_*.app 2>/dev/null | grep -vi beta | sort -V | tail -1)
sudo xcode-select -s "$X/Contents/Developer"
xcodebuild -version
