# Development notes

How the app stores its library, how the widget works, signing and the App Group, and the project's targets. Back to the [README](../README.md).

## Data

Decks and cards are stored as `decks.json` (versioned, written atomically) in the App Group
container, so the app and the widget read the same file. An unreadable file is moved aside as
`decks.corrupt-<timestamp>.json` and the app starts with an empty library. Model and storage code
lives in `Shared/` and is compiled into both targets.

The file is `{ "version": 3, "subjects": [...], "decks": [...] }`. Both lists are flat and in order.
A **subject** has an `id`, `name`, `color` and `parentID` (nil is the top level); a **deck** may carry a
`subjectID` (nil is a loose deck). Subjects nest at most `Subject.maxDepth` (3) levels; that is one
constant and nothing stored depends on it. Because decks stay one flat array, search, the widget, the
notch and playback never need to know about subjects, and filing a deck never changes its id, so its
review schedule stays with it.

- **Versions.** 1 and 2 files load unchanged with no subjects. Version 3 is what is written now. An older
  build refuses a newer version (the file is left aside as `decks.corrupt-<time>.json`, not saved back
  without its subjects).
- **Repair.** A file that was damaged outside the app is repaired as it is read, and what was done is
  logged: a missing parent or a cycle puts the subject at the top level, a subject deeper than the cap
  goes to the top level, and a deck in a missing subject becomes a loose deck. No deck or card is dropped.
- **Deleting a subject** moves its decks and sub-subjects up one level; `deleteSubjectAndContents` is the
  separate, destructive choice. Moving and deleting decks and subjects are undoable (⌘Z): the store
  records what a change touched and puts back only that, so a rename or a card edited since is kept. A
  deleted deck's pictures are kept until Undo can no longer bring it back.

## How the widget rotates

Every widget gets a prepared timeline: an entry for now and one for each 5-minute slot over the
next hour, each showing the card `CardScheduler` picks at that moment (the same function the app's
"Now showing" panel and the notch use). WidgetKit swaps entries as their dates arrive, and the
widget asks for a fresh timeline when the last prepared slot ends.

The app reloads all widget timelines after every deck edit, flip, skip and settings change.

**Sleep and wake.** Correctness doesn't depend on a timer firing on time: each entry's card is
computed from the clock, and WidgetKit shows the latest entry whose date has passed, so after a
wake the right card is the one on screen. A unit test simulates waking 1 to 59 minutes late. What
macOS controls, and what this app can't change, is *when* it redraws: expect the card to update
within moments of a boundary normally, but possibly a little late (or only when the widget next
renders) while the Mac is asleep or under heavy load, and the hourly timeline refresh is subject
to WidgetKit's refresh budget. The "Next in" countdown ticks by itself; the progress bar is drawn
once per timeline entry (see below).

To check this on a real Mac: add a widget, note the card and countdown, sleep the Mac for longer
than 5 minutes, wake it, and confirm the card matches the main window's "Now showing" panel
within a short time. Record any lag you see here.

## Don't use `ProgressView(timerInterval:)` in the widget

WidgetKit lays out live timer views (`ProgressView(timerInterval:)`) inside NotificationCenter, not
in the widget extension. In the medium widget that crashed NotificationCenter on every launch with
`view origin is invalid: (nan, 3.0)`, which removed every widget from the desktop and left Edit
Widgets empty. The bar is a static `CountdownProgressBar` per entry instead. `Text(timerInterval:)`
for the countdown has not shown the problem. If widgets vanish and `~/Library/Logs/DiagnosticReports`
fills with `NotificationCenter-*.ips`, check `log show` for that message first.

## App icon and first launch

The icon (Frosted Midnight: a stack of cards with a fish) is generated, not drawn by hand:

```sh
swift Scripts/make-icon.swift FishBrain/Assets.xcassets/AppIcon.appiconset
```

It writes every macOS size (16 to 512 pt at 1x and 2x) and `Contents.json`; `AppIconTests` checks the sizes.

On first launch, an empty library gets a "Getting Started" deck (`Shared/GettingStarted.swift`) and a welcome sheet explains how to add the widget (right-click the desktop, Edit Widgets). Both happen once: the flags `gettingStartedHandled` and `hasSeenWelcome` live in `settings.json`, so a deleted deck never comes back by itself. Help has "Welcome to FishBrain" and "Add Getting Started Deck" to see either again.

## Where the library is stored

The app and the widget must read the same files. With a properly provisioned App Group (a build
signed with a developer team) they share the group container. Without a team, macOS gives each
process its own private folder instead, so both targets are granted a narrow sandbox exception for
`~/Library/Application Support/FishBrain/` and share that. `AppGroup.storageDirectory()` picks
whichever applies, and on launch the app copies an existing library over from the old private
location (copy only, never overwriting). The exception can be dropped for builds that always ship
with a team.

`-FishBrainPrintLibrary` (Debug builds) prints which folder the app reads and what is in it, then quits.
`-FishBrainPrintNotch` prints each display's notch measurements and where the notch panel is placed.

## Troubleshooting the widget during development

- **Widget is blank, or ignores a change to its sizes or configuration.** macOS caches the widget's
  description per bundle version. Bump `CURRENT_PROJECT_VERSION` in `project.yml` whenever the
  widget's kind, sizes or intent change.
- **"Bundle version did not match" in the logs.** Two copies of the app are registered under the
  same IDs, or an old widget process is still running. Unregister the stale one with
  `lsregister -u <path-to-old-FishBrain.app>`, stop the widget process (`pkill -x FishBrainWidget`),
  and re-register the current build with `lsregister -f -R <path-to-FishBrain.app>`.
- **Widget shows only gray placeholder bars.** The extension is crashing every time macOS asks it for
  content. Look for `view origin is invalid` in its log:
  `/usr/bin/log show --last 10m --info --predicate 'process == "FishBrainWidget"'`. That is a layout
  producing a NaN or infinite size; the live countdown text can't be measured in the extension, so it
  must sit in a fixed-width frame (never `.fixedSize()`), and nothing next to it may do arithmetic on
  an unmeasured width. ImageRenderer and plain windows do not reproduce it; only the real extension does.
- **Widget shows "No cards yet" but the app has cards.** The two are reading different folders; run
  the app with `-FishBrainPrintLibrary` and check the path. Also check which deck the widget shows
  (Edit Widget); the default is the first deck.
- Read widget logs with `/usr/bin/log show --last 10m --info --predicate 'process == "FishBrainWidget"'`
  (plain `log` is shadowed by a zsh builtin).

## Signing and App Group

By default the project is ad-hoc signed (`CODE_SIGN_IDENTITY = -`), so it builds without an
Apple Developer account. The App Group is `$(TeamIdentifierPrefix)io.github.phdz-ng.fishbrain`
(see `Config/Base.xcconfig`) and is shared by the app and the widget.

macOS may not load a widget extension that isn't signed with a real team. To sign with your own team,
copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM`.
That file is gitignored. The App Group then becomes `<TEAMID>.io.github.phdz-ng.fishbrain`.

## Releasing

See [RELEASING.md](RELEASING.md): 1.0 ships as an unsigned DMG built with `Scripts/release.sh --unsigned` (no Apple account needed); `TEAM_ID=… Scripts/release.sh` builds, signs, notarizes and staples one if you have a Developer ID. Release notes are in [CHANGELOG.md](../CHANGELOG.md).

## Targets

| Target | Purpose |
| --- | --- |
| `FishBrain` | macOS app, sandboxed, read-write access to user-selected files (import and export) |
| `FishBrainWidget` | WidgetKit extension, sandboxed, embedded in the app |
