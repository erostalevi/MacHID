# Homebrew cask template for the MacHID app. Do not edit the placeholders by hand:
# scripts/update-cask.sh <version> <sha256> writes the finished file for the tap.
cask "machid" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/erostalevi/MacHID/releases/download/v#{version}/MacHID-#{version}.dmg"
  name "MacHID"
  desc "Manage mouse, keyboard and camera settings"
  homepage "https://github.com/erostalevi/MacHID"

  depends_on macos: ">= :sonoma"

  app "MacHID.app"

  # The `machid` command line tool is not installed by this cask: a cask `binary` stanza must point inside the
  # app bundle and the CLI is a separate download (machid-<version>-macos-arm64.zip on the same release).
  # See docs/HOMEBREW.md.

  zap trash: [
    "~/Library/Application Support/MacHID",
    "~/Library/Preferences/app.machid.MacHID.plist",
  ]
end
