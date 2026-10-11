#!/bin/sh
set -eu
cd "$(dirname "$0")/../ios"
xcodebuild -project CanDid.xcodeproj -scheme CanDid -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
