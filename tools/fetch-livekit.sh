#!/usr/bin/env bash
# Usage: tools/fetch-livekit.sh <darwin|linux|windows> <arm64|amd64>
# Installs livekit-server (version in tools/livekit-version.txt) into
# vendor/livekit/<os>-<arch>/. Exits non-zero on any checksum mismatch.
#
# linux/windows: release asset from github.com/livekit/livekit, verified
# against the release's checksums.txt.
# darwin: upstream publishes no macOS asset, so use the Homebrew bottle
# (Homebrew verifies the bottle's sha256) and check its version matches.
set -euo pipefail

os=${1:?usage: $0 <darwin|linux|windows> <arm64|amd64>}
arch=${2:?usage: $0 <darwin|linux|windows> <arm64|amd64>}
root=$(cd "$(dirname "$0")/.." && pwd)
version=$(tr -d '[:space:]' < "$root/tools/livekit-version.txt")
dest="$root/vendor/livekit/$os-$arch"
exe=livekit-server
[ "$os" = windows ] && exe=livekit-server.exe

case "$arch" in arm64|amd64) ;; *) echo "bad arch: $arch" >&2; exit 2;; esac
mkdir -p "$dest"

if [ "$os" = darwin ]; then
  [ "$arch" = arm64 ] || { echo "darwin: only arm64 supported" >&2; exit 2; }
  command -v brew >/dev/null || { echo "darwin needs Homebrew" >&2; exit 1; }
  brew list livekit >/dev/null 2>&1 || brew install livekit
  src="$(brew --prefix livekit)/bin/livekit-server"
  got=$("$src" --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ "$got" = "$version" ] || { echo "brew livekit is $got, want $version" >&2; exit 1; }
  cp "$src" "$dest/$exe"
  chmod +x "$dest/$exe"
  echo "installed $dest/$exe"
  exit 0
fi

case "$os" in
  linux) ext=tar.gz;;
  windows) ext=zip;;
  *) echo "bad os: $os" >&2; exit 2;;
esac
asset="livekit_${version}_${os}_${arch}.${ext}"
base="https://github.com/livekit/livekit/releases/download/v${version}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$asset" "$base/$asset"
curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt"

want=$(awk -v a="$asset" '$2 == a {print $1}' "$tmp/checksums.txt")
[ -n "$want" ] || { echo "no checksum entry for $asset" >&2; exit 1; }
if command -v sha256sum >/dev/null; then
  have=$(sha256sum "$tmp/$asset" | awk '{print $1}')
else
  have=$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')
fi
[ "$have" = "$want" ] || { echo "checksum mismatch for $asset" >&2; exit 1; }

if [ "$ext" = zip ]; then
  # bsdtar (Windows tar / macOS) reads zip; fall back to unzip.
  if command -v unzip >/dev/null; then unzip -qo "$tmp/$asset" -d "$tmp/x"
  else mkdir "$tmp/x" && tar -xf "$tmp/$asset" -C "$tmp/x"; fi
else
  mkdir "$tmp/x" && tar -xzf "$tmp/$asset" -C "$tmp/x"
fi
[ -f "$tmp/x/$exe" ] || { echo "$exe not in archive" >&2; exit 1; }
cp "$tmp/x/$exe" "$dest/$exe"
chmod +x "$dest/$exe"
echo "installed $dest/$exe"
