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
`%APPDATA%\dev.hubbub` until you delete that folder.

If Windows Firewall asks whether to let Hubbub or its media server talk on your network, choose Allow.

If you cannot see "Run anyway" (Windows 11 with Smart App Control on, or a managed PC), the installer
is blocked by the system and cannot be run until Hubbub is signed.

## Linux

Download **HubbubLinux.AppImage**, make it executable (`chmod +x HubbubLinux.AppImage`) and run it.
It updates itself like the Windows version.
