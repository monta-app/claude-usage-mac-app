#!/bin/bash
# Runs the unit tests. The extra flags are only needed on machines with the
# Command Line Tools but no full Xcode, where swift-testing's Testing.framework
# and lib_TestingInterop.dylib aren't on the default runtime search path.
set -euo pipefail
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
INTEROP=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [ -d "$FW/Testing.framework" ]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$INTEROP" "$@"
else
  exec swift test "$@"   # full Xcode present — no extra flags needed
fi
