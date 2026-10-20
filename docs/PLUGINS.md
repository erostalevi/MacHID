# Writing and sharing a MacHID plugin

A plugin teaches MacHID about devices it does not know yet. A plugin is **data only** by default: it describes a device (its USB ID, which driver family talks to it, and what it can do) and MacHID executes nothing from it. For new protocols see [Code plugins](#code-plugins-new-protocols).

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

## Code plugins (new protocols)
If your device speaks a protocol none of the built-in drivers know, a plugin can ship a JavaScript driver. The script never touches the device itself: it runs in a separate, sandboxed process (`MacHIDPluginHost`, JavaScriptCore under a `sandbox-exec` deny-default profile) and asks MacHID, through a broker, to send or read HID reports. MacHID checks every request against the permissions in your manifest.

### Manifest and definition
```json
{
  "id": "acme-mouse", "name": "Acme Mouse", "version": "1.0.0", "license": "MIT", "author": "You",
  "core_api": { "min": 1, "max": 1 }, "devices": ["1234:0001"],
  "driver": "driver.js",
  "permissions": { "transport": "hid", "report_ids": [1, 2], "writes": "volatile" }
}
```
The definition in `devices/` sets `"driver": "plugin:acme-mouse"` (the plugin id) and picks the HID interface by report size with `driver_options`: `"feature_report_size": "64"` or `"output_report_size": "20"`. Only `hid` is allowed for code plugins.

### Script API
Define `read(capability)` (returns a number, boolean, string, `{r,g,b}` or `{effect,color}`) and `write(capability, value)`; `describe()` is optional. `capability` is the capability id string. Only these globals exist:

| Call | Does |
|---|---|
| `hid.sendFeature(reportID, bytes)` | feature report to the device (a write) |
| `hid.sendOutput(reportID, bytes)` | output report (a write) |
| `hid.getFeature(reportID, length)` | returns an array of bytes |
| `hid.nextInput(timeoutMs)` | next input report `{reportID, bytes}` or `null` on timeout; only report ids you declared are delivered |
| `log(msg)` | diagnostic line (20 per request, 200 characters) |
| `sleep(ms)` | pause (at most 200 ms) |

There is no file, network, process, timer or module access.

### Limits and permissions (enforced by MacHID, not by the script)
- Script: one UTF-8 file, at most 128 KB, copied as `driver.js`. Each read or write starts a fresh host, with a 5 s total time limit; the host is killed on timeout, on a protocol error or on any violation.
- At most 64 device calls per request, 256 bytes per call, 200 calls and 50 writes per second.
- `report_ids` is a whitelist for every call; missing or empty means none (and no input at all). `writes: none` forbids every send; `persistent` is not allowed.
- A plugin never receives keyboard events: input reports are only handed over if their id is in `report_ids`, and the interface is chosen by report size, so declare only the ids your protocol uses.
- `interfaces` in the manifest is informational: the interface is chosen by report size.

### Example `driver.js`
```js
function read(capability) {
  if (capability !== "dpi") throw new Error("unsupported");
  var r = hid.getFeature(1, 4);
  return r[1] * 256 + r[2];
}
function write(capability, value) {
  hid.sendFeature(1, [2, (value >> 8) & 255, value & 255]);
}
```

### Installing and updating
MacHID asks for explicit confirmation (a checkbox) with a strong warning; community plugins also show the script size and SHA-256. **Code plugins never update automatically**, even when reviewed: every update needs approval. Without `/usr/bin/sandbox-exec` or the `MacHIDPluginHost` binary next to the app, code plugins fail; there is no unsandboxed fallback.
