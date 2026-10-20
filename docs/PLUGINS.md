# Writing and sharing a MacHID plugin

A plugin teaches MacHID about devices it does not know yet. In this version a plugin is **data only**: it describes a device (its USB ID, which driver family talks to it, and what it can do). It cannot run code, and MacHID never executes anything from it.

## What a plugin can describe
A device that speaks a protocol MacHID already has a driver for: Razer reports (`razer`), Logitech HID++ 2.0 (`logitech-gseries`) or USB Video Class cameras (`uvc`). A brand-new protocol needs a code driver, which this version does not install.

## Layout
```
manifest.json
devices/
  my-device.json      one file per device model
```

### manifest.json
```json
{
  "id": "acme-mouse",
  "name": "Acme Mouse",
  "version": "1.0.0",
  "license": "MIT",
  "author": "Your name",
  "core_api": { "min": 1, "max": 1 },
  "devices": ["1234:0001"],
  "permissions": { "transport": "hid", "writes": "volatile" }
}
```
`writes` may be `none` or `volatile`; writing to a device's own memory is not allowed. The license must be an SPDX id compatible with GPLv3 (MIT, BSD, Apache-2.0, GPL-3.0-or-later, ...). [Schemas/plugin-manifest.schema.json](../Schemas/plugin-manifest.schema.json) describes every field.

### devices/my-device.json
Follows [Schemas/device-definition.schema.json](../Schemas/device-definition.schema.json); see the files in `Definitions/` for working examples. Every USB ID used here must also appear in the manifest's `devices`. Per-model driver parameters go in `driver_options`, for example a Razer model:
```json
"driver": "razer",
"driver_options": { "lighting_transaction_id": "0x3F" }
```
Take parameters from the open protocol notes for your model (OpenRazer, libratbag, Solaar), and test with `machid get/set` before publishing.

## Publishing
1. Put the plugin in a public GitHub repository and tag the commit you want reviewed.
2. Compute the manifest's hash: `shasum -a 256 manifest.json`.
3. Open a pull request to this repository that adds an entry to `plugins.json`:
```json
{
  "id": "acme-mouse",
  "repo": "https://github.com/you/acme-mouse",
  "ref": "<the full 40-character commit SHA>",
  "manifest_sha256": "<the hash from step 2>",
  "license": "MIT",
  "category": "mouse",
  "devices": ["1234:0001"],
  "core_api": { "min": 1, "max": 1 },
  "review": "community"
}
```
CI checks the entry, downloads that exact commit and compares the manifest hash. A maintainer reviews the definitions and may mark the plugin `reviewed`.

## How MacHID installs and updates it
- The registry list is signed; MacHID ignores any list whose signature does not verify.
- The commit is pinned: MacHID downloads that exact SHA, refuses archives with links or paths that escape, and keeps only `manifest.json` and the definition files.
- Community plugins always ask before installing or updating. Reviewed plugins update automatically only when their permissions and license are unchanged.
- To publish a new version, open another pull request that changes `ref` and `manifest_sha256`.
