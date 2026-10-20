# MacHID: notes for working in this repo

macOS menu bar app + CLI that manages mouse, keyboard and camera settings without vendor software. Swift package (macOS 14+), GPLv3. Hexagonal layout: `MacHIDDomain` (pure model, ports) <- `MacHIDApplication` (use cases) <- adapters (`MacHIDIOKit`, `MacHIDQuartz`, `MacHIDSystem`, drivers `MacHIDRazer`/`MacHIDLogitech`/`MacHIDUVC`) <- `MacHIDUI`/`MacHIDApp`/`machid`. Read docs/HANDOFF.md (state, hardware facts, open work), README.md and docs/SPEC.md first; every change gets a record in docs/changes/ (Spanish) per the engineering process.

## Build and test
- `~/Documents` is iCloud-synced and its File Provider attributes make `codesign` fail on test bundles. Never build in the repo tree: `swift build|test|run --scratch-path /private/tmp/<dir>`.
- `scripts/make-app.sh` builds `MacHID.app` (to /tmp/machid-app); `swift run MacHIDSnapshots <outdir> Definitions` renders views offscreen (layout and controls only, no glass).
- Do not capture the user's screen to check the UI.

## Rules that matter
- Device writes are volatile only; verify every protocol command in open sources (OpenRazer, libratbag, Solaar, Linux uvcvideo) before writing it, and test on hardware through the user's Terminal (the agent process lacks Input Monitoring).
- Remapping is off by default and never logs content; macros with shell/open/Shortcuts, and all imported macros, need approval tied to a fingerprint of the steps.
- Plugins are data-only unless stated otherwise; nothing from a plugin is executed outside the sandboxed host.
- Commit with explicit paths (`git add Sources Tests ...`), never `git add -A` (agent worktrees live in `.claude/`). Push to origin/master after each milestone; CI is `.github/workflows` (release builds and tests even without signing secrets).
- User-facing text: English literals in views, Spanish translations in Resources/Localizable.xcstrings.
