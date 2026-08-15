# Homebrew cask for iShrink.
#
# THIS FILE DOES NOT LIVE HERE AT RUNTIME. Homebrew only reads casks out of a
# tap repository, so the installable copy belongs at:
#
#     Kalantri007/homebrew-tap  →  Casks/ishrink.rb
#
# The repository name must be exactly `homebrew-tap`. Homebrew strips the
# `homebrew-` prefix to derive the tap name, so `Kalantri007/homebrew-tap`
# becomes the tap `Kalantri007/tap`. Any other name will not resolve.
#
# This copy is kept in the app repository as the source of truth, so the cask
# is reviewable alongside the release workflow that produces the artifact it
# points at. Copy it into the tap when publishing. (The plan's deferred
# "automated cask bumping" work would eventually have CI do that copy.)
#
# ---------------------------------------------------------------------------
# BEFORE THIS CASK WILL INSTALL ANYTHING, replace two values below with the
# ones printed in the GitHub release notes: `version` and `sha256`.
#
# The placeholders are deliberately a real-looking-but-impossible pair: an
# all-zero checksum is valid syntax that can never match a real file, so an
# unconfigured cask fails with a clear checksum mismatch instead of installing
# something unverified.
# ---------------------------------------------------------------------------

cask "ishrink" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Kalantri007/iShrink/releases/download/v#{version}/iShrink-#{version}.zip"
  name "iShrink"
  desc "Compresses an Apple Photos library to reclaim local disk space"
  homepage "https://github.com/Kalantri007/iShrink"

  # The app targets macOS 12.0. The bare symbol form means "this version or
  # newer" — the `">= :monterey"` string form is deprecated in current
  # Homebrew and emits a warning on every install.
  depends_on macos: :monterey

  app "iShrink.app"

  # No `--no-quarantine` and no equivalent. Homebrew removed that flag in 5.1
  # and it is not available to third-party taps, so the quarantine step below
  # is genuinely manual. Do not add a `postflight` block that shells out to
  # xattr either: that would be the same suppression by another name, and it
  # would run without the user understanding what it does or why.
  caveats <<~EOS
    Two things you need to know, both consequences of iShrink being free to
    distribute rather than signed with a paid Apple Developer ID.

    1. macOS will refuse to open it until you clear the quarantine flag.

       Anything downloaded from the internet gets flagged by macOS, and
       normally the developer's paid signature is what clears it. iShrink has
       no such signature, so you clear it yourself, once:

         sudo xattr -rd com.apple.quarantine /Applications/iShrink.app

       Without this you will get "iShrink is damaged and can't be opened",
       which is macOS being misleading — the app is not damaged, it is
       unsigned.

    2. It will ask for Photos access again after every update.

       Each release is signed with a throwaway identity, and macOS ties
       permission grants to that identity. A new release therefore looks like
       a brand new app to it. Re-granting access is expected, not a bug.

    iShrink never modifies your Photos library and has no network access at
    all — the macOS sandbox denies it, which you can verify in the source.
  EOS

  # The app is sandboxed, so everything it writes lives under its container
  # rather than scattered across ~/Library. These are the paths that actually
  # exist after a run; `zap` tolerates any that do not.
  zap trash: [
    "~/Library/Containers/com.ishrink.app",
    "~/Library/Application Scripts/com.ishrink.app",
    "~/Library/Saved Application State/com.ishrink.app.savedState",
  ]
end
