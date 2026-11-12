#!/bin/bash
# Runs the test suite. With only the Command Line Tools installed (no Xcode), SwiftPM only
# enables swift-testing when the framework search path is passed on the command line.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ ! -d /Applications/Xcode.app ] && [ -d "$CLT/Testing.framework" ]; then
  exec swift test -Xswiftc -F"$CLT" "$@"
fi
exec swift test "$@"
