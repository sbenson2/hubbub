# Releasing Hubbub (Windows, then Linux and macOS)

Prerequisites: `vpk` (`dotnet tool install -g vpk`), the Flutter SDK, and `tools/fetch-livekit.sh`
already run so `livekit-server.exe` is bundled. The update feed URL in `app/lib/install.dart`
(`kUpdateFeed`) must be the real `.../releases/latest/download` of this repo
(`https://github.com/sbenson2/hubbub`). Before 0.1.1 the feed was the separate
`sbenson2/hubbub-releases` repo; 0.1.1 was published there once so those copies move over.

Friends update at different times, so builds that talk to each other differ. Before changing a wire
message, read the compatibility rule above `CtlMsg` in `core/src/proto.rs`.

## Windows, per release

1. Bump `version:` in `app/pubspec.yaml` (`0.1.1+2`; the part before `+` is the release version and
   must go up). Commit.
2. `cd app` then `flutter build windows --release` (with the Flutter SDK's `bin` on your PATH).
3. `powershell -File tools\package-windows.ps1` from the repo root. It writes `dist\windows`.
   **Keep `dist\windows` between releases.** vpk reads the earlier full packages and
   `releases.win.json` there to build the delta; a fresh empty folder gives a full package only.
4. On this repo's GitHub Releases, create a release tagged with the version and upload every file the
   script left that matters: `HubbubSetup.exe`, `releases.win.json`, the new
   `Hubbub-<ver>-full.nupkg` and `Hubbub-<ver>-delta.nupkg`. Do not upload the other files.
5. Mark it as the latest release (not a pre-release): clients read
   `releases/latest/download/releases.win.json`, which GitHub redirects to the latest release only.

### Keeping deltas working with `latest/download`

`latest/download/<file>` resolves to a file on the latest release only. An installed copy that is
several versions behind reads the feed, then fetches the packages it names from that same place.
So each new release should also carry the earlier `*-full.nupkg` and `*-delta.nupkg` files that
`releases.win.json` still lists: re-upload them from `dist\windows` to the new release. If a listed
package is missing, that client's update may fail (we have not tested this), and it would try again
later; a copy that cannot get deltas needs the full package of the newest version, so
at least always upload the newest `-full.nupkg`.

## Prerelease for testers (Windows)

For a beta that friends install by hand, without touching the update feed:

1. Bump `version:` in `app/pubspec.yaml` to `x.y.z-beta.N+B` (for example `0.1.2-beta.1+3`).
   `tools/package-windows.ps1` accepts a SemVer prerelease; Velopack orders `0.1.2-beta.1` below `0.1.2`.
2. `cd app` then `flutter build windows --release`. Its CMake step checks the libwebrtc zip against
   the sha256 in `third_party/flutter_webrtc/third_party/libwebrtc_version.ini` (our 48 kHz build; see
   `third_party/libwebrtc-hubbub/README.md` for its zip prerelease tag and how to publish a new one).
3. `powershell -File tools\package-windows.ps1 -OutDir dist\windows-beta`. A separate folder keeps
   `dist\windows`, the real feed history, clean.
4. `gh release create vX.Y.Z-beta.N --prerelease --latest=false` with `dist\windows-beta\HubbubSetup.exe`
   and the full nupkg (`Hubbub-X.Y.Z-beta.N-full.nupkg`). Do not upload `releases.win.json`.
5. Testers download `HubbubSetup.exe` from that page. The feed stays on the latest normal release, so
   beta installs only move when the next normal release ships (a higher version than the beta).

## Linux (manual download, no self-update yet)

In WSL: `cd ~/dev/hubbub/app && flutter build linux --release`, then `tools/package-linux.sh`.
Upload `dist/linux/HubbubLinux.AppImage` to the same release.

## macOS (manual download, no self-update yet)

On an Apple silicon Mac with `vpk`: `tools/fetch-livekit.sh darwin arm64` once, then
`cd app && flutter build macos --release` and `tools/package-macos.sh`. Upload `dist/macos/HubbubMac.pkg`
to the same release. The app is ad-hoc signed, not notarized; notarizing needs an Apple Developer
account and vpk's `--signAppIdentity`, `--signInstallIdentity` and `--notaryProfile`.
