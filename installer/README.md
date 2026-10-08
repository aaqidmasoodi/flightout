# FlightOut installers

## Windows
`build_windows.bat` exports the game (Godot preset "Windows Desktop", output `build/windows/`) and compiles
`flightout.iss` with Inno Setup 6 into `build/installer/FlightOut-<version>-Windows-Setup.exe`.

- Per-user install by default (no admin prompt), with an option to install for all users.
- Licence page, install location, Start menu and optional desktop shortcut, "Launch FlightOut" at the end.
- Registers an uninstaller in Windows Settings. Uninstalling asks before removing saved settings (never in silent mode).
- Requires 64-bit Windows 10 1809 or later; warns if neither Vulkan nor DirectX 12 is present.
- Art: `art/` (wizard images at 100 to 250% DPI, icon). Licence: `license.txt`. Notices: `THIRD-PARTY-NOTICES.txt`.

To release a new version, update `config/version` in project.godot, the version fields in export_presets.cfg,
and `AppVersion` in flightout.iss.template / flightout.iss.

## Code signing
Unsigned installers trigger Windows SmartScreen ("Windows protected your PC"). Before a public release, sign
`FlightOut.exe` and the setup with an Authenticode certificate (Inno Setup `SignTool` directive).
