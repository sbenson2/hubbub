# Installing Hubbub

## Windows

1. Download **HubbubSetup.exe** from the latest release.
2. Run it. Windows shows "Windows protected your PC" because the installer is not signed yet:
   click **More info**, then **Run anyway**.
3. That's it. Hubbub installs for your account only (no admin password), starts, and asks for your name.

Hubbub then starts with Windows and lives in the tray, so your servers stay online; turn that off in
User Settings, Windows Settings. It updates itself: when a new version is ready a bar says
"Update ready" with a Restart button. It never restarts during a call.

To remove it, use Settings, Apps, Hubbub, Uninstall. Your servers and name stay in
`%APPDATA%\dev.hubbub\hubbub` until you delete that folder.

Windows Firewall may ask whether to let Hubbub talk on your network. Choose Allow. (We have not
tested what happens if you decline.)

If nobody hears you, check Settings, Privacy & security, Microphone: **Let desktop apps access your
microphone** must be on. When it is off, Hubbub joins the call and sends silence, without an error.

If you cannot see "Run anyway" (Windows 11 with Smart App Control on, or a managed PC), the installer
is blocked by the system and cannot be run until Hubbub is signed.

## Linux

Download **HubbubLinux.AppImage**, make it executable (`chmod +x HubbubLinux.AppImage`) and run it.
It needs FUSE to run an AppImage (Fedora: `sudo dnf install fuse fuse-libs`; Ubuntu: `libfuse2`) and the
appindicator library for the tray icon (Fedora: `libayatana-appindicator-gtk3`; Ubuntu:
`libayatana-appindicator3-1`); without the library Hubbub does not start. On GNOME the tray icon also
needs the AppIndicator shell extension. Screen sharing is not available on Wayland; on Linux a screen
share carries the picture only, no sound.
Linux does not update itself yet: to update, download the new AppImage from the latest release and
replace the old one.
