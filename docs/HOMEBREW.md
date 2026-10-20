# Installing MacHID with Homebrew

MacHID is distributed as a cask (the signed, notarized DMG) from a tap, a separate GitHub repository named `erostalevi/homebrew-machid`. The template is `packaging/homebrew/machid.rb`.

## Create the tap (once)
1. Create a public repository `erostalevi/homebrew-machid` (the `homebrew-` prefix is required).
2. Add a `Casks/` folder and a short README.
3. Users then run:
```
brew tap erostalevi/machid
brew install --cask machid
```

## Publish a version
1. Wait for the release `v<version>` to have `MacHID-<version>.dmg` and `SHA256SUMS` (see docs/RELEASE.md).
2. Take the DMG hash from `SHA256SUMS` (or `shasum -a 256 MacHID-<version>.dmg`).
3. Generate the cask:
```
scripts/update-cask.sh 1.42 <sha256> /path/to/homebrew-machid/Casks/machid.rb
```
4. Commit and push in the tap repository. Check it with `brew audit --cask --online erostalevi/machid/machid` and `brew install --cask erostalevi/machid/machid`.

The version has no leading `v`; the URL adds it: `https://github.com/erostalevi/MacHID/releases/download/v#{version}/MacHID-#{version}.dmg`. The app updates itself with Sparkle, so the cask can be updated less often than releases (or add `auto_updates true` to the template if you want Homebrew to leave updates to the app).

## The command line tool
A cask `binary` stanza must point to a file inside the installed app, and `machid` is not in the app bundle; it ships as `machid-<version>-macos-arm64.zip` on the release. Options:
- Download that zip, unzip it and put `machid` on your `PATH` (for example `/usr/local/bin`).
- Later: add a formula to the same tap that installs that zip (`brew install erostalevi/machid/machid-cli`), or put the CLI inside the app bundle and add a `binary "#{appdir}/MacHID.app/Contents/MacOS/machid"` stanza. Neither is done yet.

## Automating
A workflow in the tap repository can run `scripts/update-cask.sh` on a schedule or from a `repository_dispatch` sent by the release job. The release workflow is not changed by this document.
