# machid command line

`machid` talks to attached devices and to the same settings files as the MacHID app. It is for scripting and diagnostics.

## Exit codes
| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | Runtime error (device not found, write failed, missing permission, file problem) |
| 2 | Usage error (unknown command, missing or invalid argument) |
| 3 | Refused for safety (for example a macro that is not approved) |

## Global options
`--json` (list, info, doctor, profile list/show, macro list), `--all` (list unsupported devices too), `--trace` (print raw protocol bytes of get/set to stderr), `--definitions <dir>` (device definitions folder; default `./Definitions`, then next to the executable), `--device <vvvv:pppp>` (profile apply).

## Environment
`MACHID_SUPPORT_DIR` replaces `~/Library/Application Support/MacHID` (profiles, remap, automation, plugins, macro log). Useful for tests; the app does not read it unless it is started with the same variable.

## Devices
```
machid list [--all] [--json]
machid info 1532:0257
machid get 046d:c092 dpi
machid set 046d:c092 dpi 1600
machid set 1532:0257 backlight spectrum      # RRGGBB, off, reactive:FF0000 ...
```
Writes are volatile: nothing is stored in the device. Reading or writing needs the Input Monitoring permission for the terminal app; without it the command fails with exit code 1.

## Profiles
```
machid profile list [--json]
machid profile show "Gaming"
machid profile apply "Gaming" --device 046d:c092
```
Profiles are the ones saved by the app (`profiles.json`); a profile is matched by name (case-insensitive) or id. `apply` writes each setting that the profile holds for that device's definition, in definition order, only for volatile writable capabilities, like the app. It prints one line per setting (`APPLIED`, `FAILED`, `SKIPPED`) and exits 1 if any failed.

## Macros
```
machid macro list [--json]
machid macro run "Open notes"
```
`list` shows name, id, number of steps and approval state, never the steps. `run` uses the same runner as the app, with its limits. A macro that opens things, runs shell commands or uses Shortcuts must have been approved in the app; otherwise `run` exits with code 3. The CLI never approves anything, and editing a macro in the app revokes its approval. Macros that type or click need the Accessibility permission for the terminal. Runs are written to the macro log (kinds and outcomes only).

## Rules
```
machid rules
```
Read-only listing of automatic profile switching rules and remap rules, including whether each feature is on.

## Doctor and diagnostics
```
machid doctor [--json]
machid diagnostics export ~/Desktop/machid-diagnostics.json
```
`doctor` shows permissions (Input Monitoring, Accessibility), attached devices with whether each has a definition, counts of definitions, plugins, profiles and macros, versions and the location of the config files. Serial numbers are shown only as the last 4 characters. It never prints typed text or macro contents.

`diagnostics export` writes the same data as JSON plus the recent macro log (kinds of steps and outcomes). It contains no commands, key codes, macro names, or user name: the home folder is replaced by `~`. Review the file before sharing it.

## Shell completions
```
machid completions zsh  > "${fpath[1]}/_machid"
machid completions bash > /usr/local/etc/bash_completion.d/machid
machid completions fish > ~/.config/fish/completions/machid.fish
```
