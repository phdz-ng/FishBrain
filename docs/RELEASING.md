# Releasing FishBrain

1.0 ships as a **direct download**: an unsigned (ad-hoc signed) DMG attached to a GitHub release, with no
Apple Developer Program membership. macOS blocks it the first time, and users allow it once in
Privacy & Security. A signed and notarized DMG is possible later (see the second half of this file).
The Mac App Store is not planned for 1.0 (see "Later: App Store" at the end).

## Releasing without an Apple Developer account (what 1.0 uses)

1. Put the version in `project.yml` (`MARKETING_VERSION`) and add its notes to `CHANGELOG.md`
   (`ReleaseTests` checks they match).
2. Build the DMG:

   ```sh
   Scripts/release.sh --unsigned
   ```

   The result is `build/release/FishBrain-<version>-unsigned.dmg`, followed by its SHA-256. The script
   checks that the app and widget are valid, hardened-runtime builds, and prints "Not notarized".
3. Install it on a different Mac (or a fresh user account), going through the "Open Anyway" steps in
   [opening-an-unsigned-app.md](opening-an-unsigned-app.md), and check: the Getting Started deck appears; the
   widget can be added (right-click the desktop > Edit Widgets); the notch works on a Mac with one. The
   widget is the part most likely to differ, because macOS may not load an extension without a real team.
4. Tag and publish. The file is uploaded as `FishBrain-unsigned.dmg` (the same file, a name that does not
   change per version) so the README's `releases/latest/download/` link always works, and the badges for
   the version and the download count update by themselves. The notes are the changelog section, the
   opening steps and the checksum:

   ```sh
   git tag v1.0 && git push origin v1.0
   cp build/release/FishBrain-1.0-unsigned.dmg build/release/FishBrain-unsigned.dmg
   DMG=build/release/FishBrain-unsigned.dmg
   gh release create v1.0 "$DMG" --title "FishBrain 1.0" --notes-file <(
     awk '/^## 1.0$/{f=1;next} /^## /{f=0} f' CHANGELOG.md
     echo; cat docs/opening-an-unsigned-app.md
     echo; echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)")
   ```

## Optional: a signed and notarized release (needs a paid Apple Developer Program account)

### One-time setup

1. In your Apple Developer account, create a **Developer ID Application** certificate and install it in
   your login keychain (Xcode: Settings > Accounts > Manage Certificates > + > Developer ID Application).
2. Create an app-specific password at appleid.apple.com, then store notarization credentials in the
   keychain once. Nothing goes into the repository:

   ```sh
   xcrun notarytool store-credentials fishbrain-notary --apple-id <your Apple ID> --team-id <TEAM_ID>
   ```
3. Find your 10-character team ID (developer.apple.com > Membership).

### Cutting a signed release

1. Put the version in `project.yml` (`MARKETING_VERSION`) and add its notes to `CHANGELOG.md`
   (`ReleaseTests` checks they match).
2. If the widget's kind, sizes or intent changed since the last release, nothing more is needed: the
   build number is the commit count, so it always grows (macOS caches the widget description per build).
3. Build, sign, notarize and staple:

   ```sh
   TEAM_ID=ABCDE12345 Scripts/release.sh
   ```

   The result is `build/release/FishBrain-<version>.dmg`, followed by its SHA-256.
4. Install it on a different Mac (or a fresh user account) and check: it opens without a Gatekeeper
   warning; the Getting Started deck appears; the widget can be added (right-click the desktop > Edit
   Widgets); the notch works on a Mac with one.
5. Tag and publish:

   ```sh
   git tag v1.0 && git push origin v1.0
   gh release create v1.0 build/release/FishBrain-1.0.dmg --title "FishBrain 1.0" --notes-file <(awk '/^## 1.0$/{f=1;next} /^## /{f=0} f' CHANGELOG.md)
   ```

`Scripts/release.sh --unsigned` builds the same DMG with ad-hoc signing and no account. Gatekeeper blocks
that file on other Macs until the user allows it once.

## What the script checks

- The widget extension is embedded; the app and the extension are validly signed with the hardened
  runtime on and without `get-task-allow` (notarization rejects both problems).
- Release builds are universal (arm64 and x86_64).
- After notarization: `stapler validate` and `spctl --assess` on the DMG.

## Things to know about signed builds

- With a team, the App Group becomes `<TEAM_ID>.io.github.phdz-ng.fishbrain` and the app and widget share
  the group container. On first launch the app copies a library saved by a development build
  (`~/Library/Application Support/FishBrain`) into it (`StorageMigration`; older copies are backed up,
  originals are left in place).
- The sandbox exception for `~/Library/Application Support/FishBrain` stays in the entitlements as the
  fallback for team-less builds. Notarization accepts it.

## Later: App Store

Not part of 1.0. It would need an App Store distribution profile with the App Group, removing the
sandbox exception above, App Store metadata and screenshots, and a review.
