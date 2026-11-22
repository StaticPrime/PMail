#!/bin/bash
# Usage: Tools/update-tor.sh [--pin]
#
# Puts the Tor Project's own Tor client in Vendor/Tor for Settings ▸ Privacy ▸ Hide IP address: the tor program and
# its libevent library, for Apple silicon and Intel Macs in one file each, with their licenses. It downloads the Tor
# Expert Bundle for macOS (which the Tor Project makes for apps that bundle Tor) for the release pinned below, and
# checks each download against the SHA-256 pinned here and against the release's own list of sums. With gpg
# installed it also checks that list's signature against the Tor Browser developers' key. Only what a client needs
# is kept: no pluggable transports and no GeoIP files.
#
# To move to a newer release, change TOR_BUNDLE_VERSION and run with --pin, which prints the new sums from the
# release's list (check its signature with gpg installed); put them below, then run again without --pin. The files
# in Vendor/Tor are committed, so building PMail never downloads anything.
set -euo pipefail

TOR_BUNDLE_VERSION="16.0.1"  # Tor 0.4.9.16
SHA256_AARCH64="0b7d022017c31e3f972d06465bcd7ac50feb66ac825547419a934914fe4bb156"
SHA256_X86_64="15464d99adc3bb4de1308260d79878336b04a1ac1aeff83e10f192de7d235946"
# The Tor Browser developers' signing key, which signs each release's list of sums.
SIGNING_KEY="EF6E286DDA85EA2A4BA7DE684E2C6E8793298290"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/Vendor/Tor"
BASE="https://dist.torproject.org/torbrowser/$TOR_BUNDLE_VERSION"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "update-tor: $*" >&2; exit 1; }

curl -fsSL --retry 3 -o "$WORK/sums.txt" "$BASE/sha256sums-signed-build.txt" || fail "couldn't download the release's list of sums"
if command -v gpg > /dev/null; then
    curl -fsSL --retry 3 -o "$WORK/sums.txt.asc" "$BASE/sha256sums-signed-build.txt.asc" || fail "couldn't download the list's signature"
    export GNUPGHOME="$WORK/gnupg"
    mkdir -m 700 "$GNUPGHOME"
    curl -fsSL --retry 3 "https://keys.openpgp.org/vks/v1/by-fingerprint/$SIGNING_KEY" | gpg --quiet --import \
        || fail "couldn't get the Tor Browser developers' key"
    gpg --quiet --status-fd 1 --verify "$WORK/sums.txt.asc" "$WORK/sums.txt" 2> /dev/null | grep -q "VALIDSIG $SIGNING_KEY" \
        || fail "the list of sums isn't signed by the Tor Browser developers"
    echo "The release's list of sums is signed by the Tor Browser developers."
else
    echo "gpg isn't installed, so the release's list of sums is checked against the sums pinned here, not its signature."
fi

listed() { awk -v name="$1" '$2 == name { print $1 }' "$WORK/sums.txt"; }
bundle() { echo "tor-expert-bundle-macos-$1-$TOR_BUNDLE_VERSION.tar.gz"; }

if [ "${1:-}" = "--pin" ]; then
    echo "SHA256_AARCH64=\"$(listed "$(bundle aarch64)")\""
    echo "SHA256_X86_64=\"$(listed "$(bundle x86_64)")\""
    exit 0
fi

for arch in aarch64 x86_64; do
    file=$(bundle "$arch")
    if [ "$arch" = aarch64 ]; then pinned="$SHA256_AARCH64"; else pinned="$SHA256_X86_64"; fi
    echo "Downloading ${file}…"
    curl -fsSL --retry 3 -o "$WORK/$file" "$BASE/$file" || fail "couldn't download $file"
    actual=$(shasum -a 256 "$WORK/$file" | awk '{ print $1 }')
    [ "$actual" = "$pinned" ] || fail "$file doesn't match the sum pinned in this script"
    [ "$actual" = "$(listed "$file")" ] || fail "$file doesn't match the release's list of sums"
    mkdir "$WORK/$arch"
    tar -xzf "$WORK/$file" -C "$WORK/$arch" tor/tor tor/libevent-2.1.7.dylib docs/tor.txt docs/libevent.txt docs/openssl.txt
done

rm -rf "$OUT/tor" "$OUT/libevent-2.1.7.dylib" "$OUT/Licenses"
mkdir -p "$OUT/Licenses"
lipo -create "$WORK/aarch64/tor/tor" "$WORK/x86_64/tor/tor" -output "$OUT/tor"
lipo -create "$WORK/aarch64/tor/libevent-2.1.7.dylib" "$WORK/x86_64/tor/libevent-2.1.7.dylib" -output "$OUT/libevent-2.1.7.dylib"
strip -x "$OUT/tor"
# In the app, tor is in Contents/Helpers and the library in Contents/Frameworks.
install_name_tool -change @executable_path/libevent-2.1.7.dylib @executable_path/../Frameworks/libevent-2.1.7.dylib "$OUT/tor" 2> /dev/null
install_name_tool -id @rpath/libevent-2.1.7.dylib "$OUT/libevent-2.1.7.dylib" 2> /dev/null
# Changing them broke their signatures; these stand in until the build signs them as part of PMail.
codesign --force --sign - "$OUT/libevent-2.1.7.dylib" "$OUT/tor"
cp "$WORK/aarch64/docs/tor.txt" "$OUT/Licenses/Tor.txt"
cp "$WORK/aarch64/docs/libevent.txt" "$OUT/Licenses/libevent.txt"
cp "$WORK/aarch64/docs/openssl.txt" "$OUT/Licenses/OpenSSL.txt"
echo "$TOR_BUNDLE_VERSION" > "$OUT/VERSION"
echo "Vendor/Tor has Tor from the Tor Expert Bundle $TOR_BUNDLE_VERSION ($(lipo -archs "$OUT/tor"))."
