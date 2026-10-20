# MacHID

A free, open source hub for mouse, keyboard and camera settings on macOS, for hardware whose vendor software does not run on current Macs. The core knows no brands; devices are described by data and driven by protocol-family drivers.

> Status: early development. Works today on a Razer Huntsman Mini, a Logitech G203 LIGHTSYNC and a Logitech Brio 100.

## What it does
- Menu bar app (no Dock icon) and a window generated from each device's capabilities, in Liquid Glass on macOS 26 and materials on macOS 14-25.
- Lighting (colors and built-in effects), brightness, DPI, polling rate, camera image controls and exposure.
- Profiles with automatic switching: when a device connects, per app in front, or a default per device.
- Software remapping of keys and extra mouse buttons, and macros (keys, clicks, text, Shortcuts, shell) with explicit approval for anything powerful.
- `machid` command line for scripting and diagnostics.

## Build and test
```
swift build
swift test            # build products must live outside an iCloud-synced folder: use --scratch-path
scripts/make-app.sh   # builds MacHID.app into /tmp/machid-app
```
Requires Xcode 16 or newer (Xcode 26 for the Liquid Glass look).

## Command line
```
machid list [--all] [--json]
machid info 1532:0257
machid get 046d:c092 dpi
machid set 046d:c092 dpi 1600
machid set 1532:0257 backlight spectrum        # or a color RRGGBB, off, reactive:FF0000 ...
machid get 046d:094c brightness --trace        # shows the raw protocol bytes
machid profile apply "Gaming" --device 046d:c092
machid macro run "Open notes"                  # refused unless approved in the app
machid doctor                                  # permissions, devices, files
machid diagnostics export report.json          # redacted
```
All commands, options and exit codes: [docs/CLI.md](docs/CLI.md).

## Layout
```
Sources/
  MacHIDDomain        pure model and ports (no frameworks)
  MacHIDApplication   use cases: inventory, device control, remap engine, macro runner
  MacHIDRazer / MacHIDLogitech / MacHIDUVC   protocol-family drivers
  MacHIDIOKit / MacHIDQuartz / MacHIDSystem  adapters and composition
  MacHIDUI / MacHIDApp                        SwiftUI app
  machid / machid-validate / MacHIDSnapshots  tools
Definitions/   device definitions (data)   Schemas/   JSON Schemas   docs/   spec, change records
```
Start with [docs/HANDOFF.md](docs/HANDOFF.md) (current state and next steps) and [docs/SPEC.md](docs/SPEC.md); every change is recorded in [docs/changes](docs/changes). Releases are described in [docs/RELEASE.md](docs/RELEASE.md).

## Safety
Writes are volatile: nothing is stored in a device's memory, and firmware is never touched. Commands come from open protocol documentation (OpenRazer, libratbag, Solaar, the Linux UVC driver) and are checked against what the device itself reports. Remapping is off until you turn it on, never records what you type, and macros that run shell commands, open things or use Shortcuts must be approved by you; editing one revokes approval. See SPEC §9.

## License
GPLv3.
