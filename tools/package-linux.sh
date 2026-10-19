#!/usr/bin/env bash
# Packages the Linux release bundle into a self-updating Velopack AppImage.
#   tools/package-linux.sh [bundle-dir] [out-dir]
# bundle-dir defaults to ~/dev/hubbub/app/build/linux/x64/release/bundle (the WSL build; build it with
# `flutter build linux --release` in WSL first, with vendor/livekit/linux-amd64/livekit-server present).
# Output (default dist/linux, git-ignored): Hubbub.AppImage (also copied to HubbubLinux.AppImage), Hubbub-<ver>-linux-full.nupkg,
# a delta when an earlier release is in the folder, and releases.linux.json (the update feed).
# vpk: a Linux `vpk` (dotnet tool) if there is one, otherwise the Windows one, which cross-packs
# Linux releases (`vpk [linux] pack`); the bundle is staged on the Windows drive for that.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
bundle="${1:-$HOME/dev/hubbub/app/build/linux/x64/release/bundle}"
out="${2:-$repo/dist/linux}"
[ -x "$bundle/hubbub" ] || { echo "no $bundle/hubbub: build the Linux app first" >&2; exit 1; }
[ -f "$bundle/livekit-server" ] || { echo "no livekit-server in the bundle (tools/fetch-livekit.sh linux amd64, then rebuild)" >&2; exit 1; }

version="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$repo/app/pubspec.yaml" | head -1)"
[ -n "$version" ] || { echo "no semver version: line in app/pubspec.yaml" >&2; exit 1; }
icon="$repo/app/assets/tray/icon.png"
mkdir -p "$out"

pack_args=(pack --packId Hubbub --packTitle Hubbub --packAuthors Hubbub --packVersion "$version"
  --mainExe hubbub --runtime linux-x64 --categories 'Network;Chat;AudioVideo')
[ -f "$icon" ] && pack_args+=(--icon "$icon")

if command -v vpk >/dev/null 2>&1; then
  vpk "${pack_args[@]}" --packDir "$bundle" --outputDir "$out"
else
  # Cross-pack with the Windows tool from a staged copy on the Windows drive. vpk sets the
  # executable bits inside the AppImage itself (checked: hubbub, livekit-server, UpdateNix).
  stage="$repo/dist/linux-stage"
  rm -rf "$stage"; mkdir -p "$stage"
  cp -a "$bundle/." "$stage/"
  [ -f "$icon" ] && pack_args=("${pack_args[@]/$icon/$(wslpath -w "$icon")}")
  cmd.exe /c vpk '[linux]' "${pack_args[@]}" --packDir "$(wslpath -w "$stage")" --outputDir "$(wslpath -w "$out")"
  rm -rf "$stage"
fi
if [ -f "$out/Hubbub.AppImage" ]; then cp -f "$out/Hubbub.AppImage" "$out/HubbubLinux.AppImage"; fi
ls -la "$out"
