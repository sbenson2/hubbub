#!/usr/bin/env bash
# Packages the macOS release build into a Velopack installer. Run it on the Mac. macOS does not
# update itself (the updater is Windows-only): updates are manual downloads from the release page.
#   tools/package-macos.sh [app-bundle] [out-dir]
# app-bundle defaults to app/build/macos/Build/Products/Release/hubbub.app (build it with
# `flutter build macos --release`, with vendor/livekit/darwin-arm64/livekit-server present).
# Output (default dist/macos, git-ignored): HubbubMac.pkg (the installer, copied from
# Hubbub-osx-Setup.pkg), Hubbub-osx-Portable.zip, Hubbub-<ver>-osx-full.nupkg and releases.osx.json.
# The app is ad-hoc signed, not notarized: on first launch macOS refuses it once, and the user
# allows it under System Settings > Privacy & Security > Open Anyway.
# Needs the vpk tool:  dotnet tool install -g vpk
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$repo/app/build/macos/Build/Products/Release/hubbub.app}"
out="${2:-$repo/dist/macos}"
[ -x "$app/Contents/MacOS/hubbub" ] || { echo "no $app/Contents/MacOS/hubbub: build the macOS app first" >&2; exit 1; }
[ -x "$app/Contents/Resources/livekit-server" ] || { echo "no livekit-server in the app (tools/fetch-livekit.sh darwin arm64, then rebuild)" >&2; exit 1; }

version="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$repo/app/pubspec.yaml" | head -1)"
[ -n "$version" ] || { echo "no semver version: line in app/pubspec.yaml" >&2; exit 1; }
PATH="$PATH:/usr/local/share/dotnet:$HOME/.dotnet/tools"
command -v vpk >/dev/null 2>&1 || { echo "vpk not found; run: dotnet tool install -g vpk" >&2; exit 1; }
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# vpk adds UpdateMac and sq.version to the bundle, so the outer app must be re-signed or its seal
# breaks. Ad-hoc ("-") and outer bundle only: the nested frameworks keep Xcode's signatures and
# livekit-server keeps its sandbox-inherit entitlements. vpk signs with the hardened runtime, whose
# library validation rejects every ad-hoc framework (no Team ID), so it is turned off on top of the
# Release entitlements.
entitlements="$work/hubbub.entitlements"
cp "$repo/app/macos/Runner/Release.entitlements" "$entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$entitlements"

vpk pack --packId Hubbub --packTitle Hubbub --packAuthors Hubbub --packVersion "$version" \
  --packDir "$app" --mainExe hubbub --runtime osx-arm64 --outputDir "$out" \
  --signAppIdentity - --signEntitlements "$entitlements" --signDisableDeep

# An app whose signature does not verify is reported as "damaged", with no Open Anyway button.
check="$work/check"
mkdir -p "$check"
ditto -x -k "$out/Hubbub-osx-Portable.zip" "$check"
codesign --verify --deep --strict "$check"/*.app || { echo "the packed app's signature does not verify" >&2; exit 1; }

cp -f "$out/Hubbub-osx-Setup.pkg" "$out/HubbubMac.pkg"
ls -la "$out"
