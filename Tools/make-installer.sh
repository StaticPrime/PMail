#!/bin/bash
# Builds build/PMail.pkg, an installer that puts PMail.app in /Applications for all users, and
# build/PMail.dSYM.zip, the app's debug symbols, for reading crash reports from that build.
#
#   Tools/make-installer.sh
#
# Sign-in with Google and Microsoft needs PMail's client IDs from each provider. They're taken from these
# environment variables when they're set (the release workflow sets them from repository secrets), or else from
# Config/Secrets.xcconfig. Without them the app builds and works with iCloud and other accounts, and its Google
# and Microsoft choices say sign-in isn't set up in that copy:
#
#   PMAIL_GOOGLE_CLIENT_ID, PMAIL_GOOGLE_CLIENT_SECRET, PMAIL_GOOGLE_REDIRECT_URI,
#   PMAIL_MICROSOFT_CLIENT_ID, PMAIL_MICROSOFT_TENANT, PMAIL_MICROSOFT_REDIRECT_URI
#
# By default the app is ad-hoc signed and the installer is unsigned. That's fine on the Mac that built
# it, but macOS blocks a downloaded copy until the user clicks Open Anyway. To sign for distribution
# with a Developer ID, set these first (the release workflow does this on GitHub):
#
#   DEVELOPER_ID_APPLICATION   the identity that signs the app, "Developer ID Application: Name (TEAMID)"
#   DEVELOPER_ID_INSTALLER     the identity that signs the installer, "Developer ID Installer: Name (TEAMID)"
#
# To also notarize the signed installer with Apple and staple the ticket to it, set either
#
#   NOTARY_PROFILE             a profile saved with `xcrun notarytool store-credentials`, or
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID
#                              an App Store Connect API key: the .p8 file, its key ID and its issuer ID
set -euo pipefail

cd "$(dirname "$0")/.."
WORK="$PWD/build/Installer"
OUTPUT="$PWD/build/PMail.pkg"
SYMBOLS="$PWD/build/PMail.dSYM.zip"
fail() { echo "make-installer: $*" >&2; exit 1; }

NOTARIZE=false
if [ -n "${NOTARY_PROFILE:-}" ] || [ -n "${NOTARY_KEY_PATH:-}" ]; then
    NOTARIZE=true
    [ -n "${DEVELOPER_ID_APPLICATION:-}" ] && [ -n "${DEVELOPER_ID_INSTALLER:-}" ] \
        || fail "notarizing needs both DEVELOPER_ID_APPLICATION and DEVELOPER_ID_INSTALLER"
    if [ -z "${NOTARY_PROFILE:-}" ]; then
        [ -f "$NOTARY_KEY_PATH" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ] \
            || fail "an API key needs NOTARY_KEY_PATH (an existing .p8 file), NOTARY_KEY_ID and NOTARY_ISSUER_ID"
    fi
fi

# The sign-in settings that are set, as build settings for the Info.plist.
SIGN_IN_SETTINGS=()
for name in PMAIL_GOOGLE_CLIENT_ID PMAIL_GOOGLE_CLIENT_SECRET PMAIL_GOOGLE_REDIRECT_URI \
            PMAIL_MICROSOFT_CLIENT_ID PMAIL_MICROSOFT_TENANT PMAIL_MICROSOFT_REDIRECT_URI; do
    if [ -n "${!name:-}" ]; then
        SIGN_IN_SETTINGS+=("$name=${!name}")
    fi
done

rm -rf "$WORK" "$OUTPUT" "$SYMBOLS"
mkdir -p "$WORK/root" "$WORK/packages"

# 1. A Release archive of the app, for Apple silicon and Intel Macs. The build log is only shown if it fails.
echo "Building PMail.app…"
if ! xcodebuild -project PMail.xcodeproj -scheme PMail -configuration Release \
        -derivedDataPath "$WORK/DerivedData" -archivePath "$WORK/PMail.xcarchive" \
        ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO ${SIGN_IN_SETTINGS[@]+"${SIGN_IN_SETTINGS[@]}"} archive > "$WORK/build.log" 2>&1; then
    grep -E "error:|\*\* ARCHIVE FAILED" "$WORK/build.log" || tail -40 "$WORK/build.log"
    echo "The build failed. The full log is in $WORK/build.log" >&2
    exit 1
fi
APP="$WORK/PMail.xcarchive/Products/Applications/PMail.app"
codesign --verify --strict "$APP"

# Its debug symbols, zipped beside the installer. Release builds are stripped, so a crash report from an installed
# copy shows only addresses in PMail; these name them. They fit this build alone, matched by the UUIDs of its
# binary (which signing again below leaves as they are).
DSYM="$WORK/PMail.xcarchive/dSYMs/PMail.app.dSYM"
uuids() { dwarfdump --uuid "$1" 2>/dev/null | awk '{ print $2, $3 }' | sort; }
SYMBOL_UUIDS=$(uuids "$DSYM" || true)
[ -n "$SYMBOL_UUIDS" ] && [ "$SYMBOL_UUIDS" = "$(uuids "$APP/Contents/MacOS/PMail" || true)" ] \
    || fail "the archive has no debug symbols that match the app"
ditto -c -k --norsrc --noqtn --keepParent "$DSYM" "$SYMBOLS"

info() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }
IDENTIFIER=$(info CFBundleIdentifier)
VERSION=$(info CFBundleShortVersionString)
MIN_OS=$(info LSMinimumSystemVersion)
HOST_ARCHS=$(lipo -archs "$APP/Contents/MacOS/PMail" | tr ' ' ',')
SIGN_IN=""
[ -n "$(info PMailGoogleClientID || true)" ] && SIGN_IN="Google"
[ -n "$(info PMailMicrosoftClientID || true)" ] && SIGN_IN="${SIGN_IN:+$SIGN_IN and }Microsoft"
SIGN_IN=", sign-in with ${SIGN_IN:-neither Google nor Microsoft}"

# 2. With a Developer ID, sign the app again for distribution: the hardened runtime, a secure timestamp,
#    and the same entitlements the build gave it. The Tor client inside it is signed first, from the inside out:
#    its library, then tor with the entitlements that keep it in PMail's sandbox, then the app around them.
if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
    echo "Signing PMail.app with the Developer ID…"
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP/Contents/Frameworks/libevent-2.1.7.dylib"
    codesign --force --options runtime --timestamp --entitlements Vendor/Tor/tor.entitlements \
        --sign "$DEVELOPER_ID_APPLICATION" "$APP/Contents/Helpers/tor"
    codesign -d --entitlements - --xml "$APP" > "$WORK/entitlements.plist" 2>/dev/null || true
    if [ -s "$WORK/entitlements.plist" ]; then
        codesign --force --options runtime --timestamp --entitlements "$WORK/entitlements.plist" \
            --sign "$DEVELOPER_ID_APPLICATION" "$APP"
    else
        codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP"
    fi
    codesign --verify --strict "$APP"
fi

# 3. The app package. Installers normally update any other copy of an app they find on the disk
#    (in a build folder, say) instead of installing it where they should, so relocation is turned off.
echo "Packaging…"
ditto "$APP" "$WORK/root/PMail.app"
pkgbuild --quiet --analyze --root "$WORK/root" "$WORK/components.plist"
index=0
while plutil -extract "$index" xml1 -o /dev/null "$WORK/components.plist" 2>/dev/null; do
    plutil -replace "$index.BundleIsRelocatable" -bool NO "$WORK/components.plist"
    index=$((index + 1))
done
pkgbuild --quiet --root "$WORK/root" --component-plist "$WORK/components.plist" --install-location /Applications \
    --identifier "$IDENTIFIER" --version "$VERSION" "$WORK/packages/PMailApp.pkg"

# 4. The installer: the startup disk only, macOS $MIN_OS or later. Signed when there's a Developer ID.
cat > "$WORK/Distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>PMail</title>
    <options customize="never" require-scripts="false" hostArchitectures="$HOST_ARCHS"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="$MIN_OS"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default">
            <line choice="$IDENTIFIER"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$IDENTIFIER" visible="false">
        <pkg-ref id="$IDENTIFIER"/>
    </choice>
    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">#PMailApp.pkg</pkg-ref>
</installer-gui-script>
EOF
if [ -n "${DEVELOPER_ID_INSTALLER:-}" ]; then
    echo "Signing the installer with the Developer ID…"
    productbuild --quiet --distribution "$WORK/Distribution.xml" --package-path "$WORK/packages" \
        --sign "$DEVELOPER_ID_INSTALLER" --timestamp "$OUTPUT"
    pkgutil --check-signature "$OUTPUT" > /dev/null
else
    productbuild --quiet --distribution "$WORK/Distribution.xml" --package-path "$WORK/packages" "$OUTPUT"
fi

# 5. Notarization: Apple checks the installer and the app inside it, then the ticket is stapled to the
#    installer so Gatekeeper accepts it even offline.
notary() {
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool "$@" --keychain-profile "$NOTARY_PROFILE"
    else
        xcrun notarytool "$@" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
    fi
}
if $NOTARIZE; then
    echo "Notarizing with Apple (usually a few minutes)…"
    notary submit "$OUTPUT" --wait --timeout 1h --output-format json > "$WORK/notary.json" || true
    STATUS=$(plutil -extract status raw -o - "$WORK/notary.json" 2>/dev/null || echo "no answer")
    if [ "$STATUS" != Accepted ]; then
        SUBMISSION=$(plutil -extract id raw -o - "$WORK/notary.json" 2>/dev/null || true)
        [ -n "$SUBMISSION" ] && notary log "$SUBMISSION" "$WORK/notary-log.json" > /dev/null 2>&1 && cat "$WORK/notary-log.json"
        fail "notarization failed ($STATUS). Apple's answer is in $WORK/notary.json"
    fi
    xcrun stapler staple -q "$OUTPUT"
    xcrun stapler validate -q "$OUTPUT"
    spctl --assess --type install "$OUTPUT" 2>/dev/null || fail "Gatekeeper doesn't accept the notarized installer"
fi

if $NOTARIZE; then STATE="signed with the Developer ID and notarized"
elif [ -n "${DEVELOPER_ID_APPLICATION:-}" ] && [ -n "${DEVELOPER_ID_INSTALLER:-}" ]; then STATE="signed with the Developer ID, not notarized"
elif [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then STATE="app signed with the Developer ID, installer unsigned, not notarized"
elif [ -n "${DEVELOPER_ID_INSTALLER:-}" ]; then STATE="app ad-hoc signed, installer signed with the Developer ID, not notarized"
else STATE="ad-hoc signed, not notarized"
fi
echo "Built $OUTPUT (PMail $VERSION, $IDENTIFIER, $HOST_ARCHS, $STATE$SIGN_IN)"
echo "Its debug symbols, for reading crash reports from it: $SYMBOLS"
