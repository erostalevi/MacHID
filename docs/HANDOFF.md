# Handoff: where the project stands and how to continue

Written so a new session can pick up without the earlier conversation. Read this, then `CLAUDE.md`, `README.md` and `docs/SPEC.md` (the spec is in Spanish; change records in `docs/changes/` are in Spanish too, code and this file are in English). Last updated at commit `0738c4c` on `master` (https://github.com/erostalevi/MacHID).

## 1. What MacHID is
A free (GPLv3) macOS menu bar app plus CLI (`machid`) that manages mouse, keyboard and camera settings without vendor software. The core knows no brands: devices are *data* (`Definitions/*.json`) driven by protocol-family drivers (Razer, Logitech HID++ 2.0, USB Video Class). Plugins add devices (data-only, or sandboxed JavaScript drivers). Owner's devices, all wired and all verified: Razer Huntsman Mini `1532:0257`, Logitech G203 LIGHTSYNC `046d:c092`, Logitech Brio 100 `046d:094c`. Owner's Mac: Apple silicon, macOS 27, Xcode 27.1, Swift 6.4.

## 2. Architecture map (hexagonal)
```
Sources/
  MacHIDDomain        pure model and ports: USBID, Capability, DeviceDefinition (+driver_options, artwork), Profile/SettingValue,
                      Automation, Remap (rules, macros), PluginManifest, Registry, DeviceArtwork (SVGSafety, ArtworkLayout), Ports (Transport, DeviceDriver)
  MacHIDApplication   use cases: DeviceInventory, DeviceControl, RemapEngine (pure), MacroRunner (+ElevationGuard), PluginInstaller,
                      PluginRegistry (RegistryService, PluginPlanner), PluginDriver (broker for code plugins)
  MacHIDRazer / MacHIDLogitech / MacHIDUVC    drivers; each pure over a Transport
  MacHIDIOKit         IOKit adapters: enumeration, HID report transport, USB control transport (IOUSBHost), hot-plug monitor, Input Monitoring check
  MacHIDQuartz        CGEventTap, event poster, shell runner, launcher (macros)
  MacHIDSystem        composition and storage: SystemDeviceConnector, SessionPool, file repositories, registry/plugin support, fingerprints, plugin host launcher
  MacHIDUI            SwiftUI models and views (AppModel, RemapController, PluginsModel, UpdaterModel, views)
  MacHIDApp           the app entry (MenuBarExtra + windows)       MacHIDPluginHost   JavaScriptCore host process for code plugins
  machid              CLI (commands split into files)               machid-validate    CI validator       MacHIDSnapshots   offscreen view renderer
Definitions/ (+artwork/)  Schemas/  Resources/Localizable.xcstrings  scripts/  packaging/homebrew  .github/workflows  docs/
```
Rule: the domain imports no platform framework; hardware sits behind `Transport`; drivers never open devices themselves.

## 3. Build, test, run (read before touching anything)
- **Never build inside the repo folder**: `~/Documents` is iCloud-synced; File Provider attributes make `codesign` fail on test bundles. Always `--scratch-path /private/tmp/<dir>`. Example: `swift test --scratch-path /private/tmp/claude-502/.../scratchpad/build`.
- `scripts/make-app.sh` builds `MacHID.app` (default `/tmp/machid-app`, ad hoc signed, embeds Sparkle and the plugin host). `OUT=... BUILD_DIR=...` override; `SIGN_IDENTITY` for Developer ID. Launch hidden for a smoke test: `open -g -j /tmp/machid-app/MacHID.app --args --background`.
- `swift run MacHIDSnapshots <outdir> Definitions` renders views offscreen to PNG (layout and AppKit controls only; **glass layers and tinted pills do not render**; the Read tool caches images by path, so use new file names).
- Do not capture the user's screen to check the UI (a screenshot once showed an unrelated full-screen app). Ask the user to look instead.
- Tests: ~190, all passing at the last run (Swift Testing). Some tests spawn real processes (`tar`, `zsh`, the plugin host). They run in seconds.
- Do not name two targets that differ only by case (`machid` vs `MacHID`): the filesystem is case-insensitive. The app target is `MacHIDApp`.
- The GitHub unauthenticated API rate-limits quickly (60/h): do not poll it in loops; `gh` is not installed. Use `git ls-remote` to resolve tags.
- Commit with explicit paths (`git add Sources Tests Resources docs ...`), never `git add -A`: agent worktrees live in `.claude/` (ignored now). Push to `origin/master` after each milestone.

## 4. Testing on real hardware (needs the user)
The agent process does not have Input Monitoring; opening HID interfaces fails with `0xe00002e2`. The user's Terminal does. Use the terminal tool (the user approves each command) or give the user a one-liner. Build once for them: `swift build --scratch-path /tmp/machid-build`, run `/tmp/machid-build/debug/machid ...`. In zsh, loop over commands with `${=c}` (zsh does not word-split unquoted variables).
Useful commands: `machid list --all`, `machid info 1532:0257`, `machid get 046d:c092 features` (lists HID++ features), `machid get/set <id> <capability> <value> [--trace]` (`--trace` prints raw protocol bytes). Safe restore after lighting tests: `machid set 1532:0257 device_mode 0`, `machid set 046d:c092 device_mode 0`.

### Hardware facts learned (do not rediscover)
- Razer Huntsman Mini: control interface is the HID device with `MaxFeatureReportSize == 90` (USB interface 2); 90-byte feature reports, report ID 0, CRC = XOR of bytes 2..<88. Lighting commands use transaction id `0x3F`, firmware/mode commands `0xFF`. **Software lighting is ignored until the keyboard is in driver mode (device mode 3)**; the driver now switches automatically. A reset of the keyboard (Left Ctrl + Esc while plugging in) did not clear the user's onboard bindings and produced a scare; do not suggest resets lightly.
- Brightness read-after-write on the Mini can lag: an immediate read can return the old value.
- Logitech G203: HID++ lives on the interface with usage page 1 / usage 6 and 20-byte output reports (report IDs 0x10 short, 0x11 long), device index 0xFF (wired). Features (from `machid get 046d:c092 features`): `0:0000 1:0001 2:0003 3:0005 4:1801 5:1802 6:1806 7:1e00 8:1e22 9:1eb0 10:2201 11:18b1 12:00c2 13:8060 14:8071 15:8100 16:8110 17:18a1 18:8081`. It has **0x8071 (RGB effects), not 0x8070**. Lighting needs host control: onboard profiles host mode (`0x8100` fn1 `[2]`) and `0x8071` fn5 `[1,3,4]`; release with `[1,0,0]` then `[1]`. DPI via 0x2201 verified (3200 default).
- Logitech Brio 100: UVC; controls via class requests on the Video Control interface; processing unit id 2 with `bmControls = 0x175B`, camera terminal id 1 with `0x0E`; no zoom/focus. Reads and brightness writes verified.
- Verified on hardware: all reads, Razer brightness/color/driver mode, G203 DPI and RGB lighting with restore, Brio brightness. **Not verified**: Razer effects (spectrum, wave, reactive, starlight), G203 cycle/breathing, polling rate, Brio exposure, battery, the event tap, every UI interaction added after M4.

## 5. Open work, in priority order
### Needs the owner
1. ~~LICENSE~~ added (GPLv3). App icon added (`scripts/make-icon.swift`).
2. GitHub secrets/variables so releases publish (see `docs/RELEASE.md`): Developer ID certificate (`DEVELOPER_ID_CERT_P12_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`, `DEVELOPER_ID_IDENTITY`), notarization (`NOTARY_API_KEY_P8_BASE64`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER_ID`), registry key (`scripts/make-registry-key.sh` -> secret `REGISTRY_SIGNING_KEY_PEM`, variable `REGISTRY_PUBLIC_KEY`), Sparkle (`generate_keys` -> secret `SPARKLE_ED_PRIVATE_KEY`, variable `SPARKLE_PUBLIC_KEY`). Without them `release.yml` builds and tests only (green) and builds are unsigned with updating and plugin discovery switched off.
3. GitHub `release` environment: required reviewers and branch restriction to `master`.
4. Telemetry collector decision (SPEC §18): only local `machid diagnostics export` exists.
5. Homebrew tap repo `erostalevi/homebrew-machid` (`docs/HOMEBREW.md`, `scripts/update-cask.sh`).
### Hardware verification (do first, it is where silent bugs can hide)
- Razer effects: `machid set 1532:0257 backlight spectrum|wave|reactive:FF0000|starlight`; then `device_mode 0`.
- G203: `backlight cycle`, `backlight breathing:00FF00`, `get/set polling_rate 125|250|500|1000`, then `device_mode 0`.
- Brio: `get/set exposure_auto 0|1`, `get/set exposure_time <n>` (100 µs units; only works with auto off).
- Event tap: enable remapping in Settings > Remap with a harmless rule (e.g. F5 -> another key), grant Input Monitoring + Accessibility to MacHID.app, confirm Force Quit (⌘⌥Esc) still works, turn it off and confirm normal typing.
- M9 (glass window, slim menu, perf; `docs/changes/M9-glass-panel-rendimiento.md`): packaged app launches and idles; **not seen on screen**: ask the user about glass corners, text contrast, window drag, menu panel.
- UI added after M4 (shortcuts ⌘1…⌘5, banner timer, macro favorites, Stop macros, onboarding, plugins and updates pages): run the app and look.
- `scripts/make-app.sh` with `MacHIDPluginHost` and a launch of the packaged app; hardened runtime with JIT off may need `allow-jit` for the host.
### End-to-end checks that need keys
- Install a real plugin from a signed registry; Sparkle update from a real release; `appcast.xml` generation; DMG signing/notarization in `release.yml`.
### Known gaps
- Code plugins: manifest `interfaces` not enforced (interface is chosen by report size); infinite JS loops stopped only by the app's timeout; sandbox network block not proven (file block is proven); the code warning appears only after download (registry entry does not say it has code).
- Data plugins: declared permissions are shown, not enforced against the built-in drivers.
- Macro approval is an HMAC with a Keychain key (M10); a same-user process with Keychain access could still sign. `ElevationGuard` is advisory.
- Registry: replay/stale lists are rejected (sequence + issue date stamped by `registry.yml`), but a local cache attacker is out of scope.
- Battery: Logitech wireless via receiver needs receiver device indexes (HID++ client only addresses 0xFF); no definition declares `battery` yet.
- Remapping cannot tell which device an event came from, and cannot use modifier keys (Caps Lock, fn) as triggers.
- Only three SVG drawings exist; other devices show generic silhouettes.
- Telemetry opt-in is not implemented.
### Ideas
More device definitions as data plugins (research each in OpenRazer/libratbag/Solaar and test); per-key Razer lighting; Logitech onboard profile editing (0x8100) with the explicit-save flow; snapshot tests if a renderer that draws glass is found; auto-open Settings pages from menu; `machid` plugin commands.

### M11 (UI redesign and per-device features)
- Window is fixed-size (1020x680): `DeviceStage` (mouse/keyboard simulation, camera preview) | `DeviceSidebar` (tabs: Lighting, Buttons, Performance, Image, Advanced, Details). Settings has its own sidebar. Records: `docs/changes/M11-*.md`.
- **The owner's keyboard is the standard Huntsman Mini (1532:0257, name "Razer Huntsman Mini", no analog HID interface).** The owner believes it is analog (used it on Windows). OpenRazer has no actuation/rapid-trigger commands and the analog model is 1532:0282, so none was implemented. If a Huntsman Mini Analog is ever available, capture its HID descriptors (`ioreg -r -c IOHIDInterface -l`) first.
- Unverified on hardware: per-key frames, Razer breathing/reactive/starlight options, G203 cycle/breathing with period/brightness/waveform, DPI presets cycling, camera preview with UVC writes at the same time, UVC reset to defaults.
- Ideas not done: tap-hold / double-tap keys in the remap engine (software "rapid tap"), live key-press echo on the drawing (needs the event tap), pointer acceleration (APIs deprecated since 10.12), per-device remap rules (the tap cannot tell devices apart).

## 6. Decisions already made (do not reopen without a reason)
- Swift native, macOS 14+, Liquid Glass via `GlassSurface` (guarded by `#if compiler(>=6.2)` and `#available(macOS 26)`; material fallback; opaque with Reduce Transparency).
- Writes are volatile only. No firmware, no onboard memory writes (`write_persistent` is rejected). Protocol commands must be verified in open sources first (OpenRazer GPL-2.0-or-later, libratbag MIT, Solaar GPL-2.0-or-later, Linux uvcvideo). Record sources in the change record.
- Release per push to `master` (version `VERSION` + commit count), registry releases tagged `registry-*` and marked not latest, the app feed is `releases/latest/download/appcast.xml`.
- Menu bar only (`LSUIElement`), window also reachable from Spotlight reopen, English first with full localization (Spanish provided).
- Opt-in anonymous telemetry was chosen, but nothing is sent until a collector exists.
- Shell macros are allowed, behind approval + a global switch + the elevation guard + timeouts; all imported macros need approval.

## 7. Where things are documented
`docs/SPEC.md` (design, §20 status), `docs/changes/*.md` (one record per milestone: M0, M1, M2, M3a/b/c, M4, M5, M6, M7 onboarding, M7 code plugins, M8 battery), `docs/CLI.md`, `docs/PLUGINS.md`, `docs/RELEASE.md`, `docs/HOMEBREW.md`, `CLAUDE.md`. The organization process asks for a change record (`docs/changes/`) for every change: add one with each new feature (objective, files, logic, decisions, risks, tests).
