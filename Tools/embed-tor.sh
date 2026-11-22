#!/bin/bash
# Run by the PMail target's "Embed Tor" build phase. Copies the Tor client from Vendor/Tor (see Tools/update-tor.sh)
# into the app: the program in Contents/Helpers, its library in Contents/Frameworks and their licenses in
# Contents/Resources/Tor. Then it signs both the way the build signs the app, tor with the entitlements that keep it
# inside PMail's sandbox. Tools/make-installer.sh signs them again with the Developer ID.
set -euo pipefail

SOURCE="$SRCROOT/Vendor/Tor"
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -n "$IDENTITY" ] || IDENTITY="-"

mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Tor"
ditto "$SOURCE/libevent-2.1.7.dylib" "$APP/Contents/Frameworks/libevent-2.1.7.dylib"
ditto "$SOURCE/tor" "$APP/Contents/Helpers/tor"
ditto "$SOURCE/Licenses" "$APP/Contents/Resources/Tor"

codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/libevent-2.1.7.dylib"
codesign --force --options runtime --sign "$IDENTITY" --entitlements "$SOURCE/tor.entitlements" "$APP/Contents/Helpers/tor"
