# How the features work

Notes on light and dark, copy to card, sharing decks, pictures, grading and reviews, the streak and accessibility. Back to the [README](../README.md).

## Light and dark

FishBrain has one light look ("Tangerine and white": white window and cards, a sidebar tinted by the
accent) and the original dark one. **Light** with the **Orange** accent is the default. Switch with the
round sun/moon button in a deck's or subject's toolbar (between Review and the menus; at narrow widths it
moves into the ⋯ menu as **Appearance ▸**), with **View ▸ Appearance**, or with the tiles at the top of
Settings > General. **Match system** follows the Mac, and the button shows a sun or a moon for whichever is
on screen. The accent (Orange, Indigo, Blue, Purple, Teal) applies in both.

- **Tokens.** Every color in `Theme.swift` is a `Token` with a dark and a light `Swatch`; views draw it as a
  SwiftUI style and it picks the value from the environment's color scheme, so no view knows which
  appearance is on. Text and glyphs on an accent or deck fill use `TextColor.onAccent` (white in both).
- **Applying it.** `AppearanceController` sets `NSApp.appearance` from the setting (nil for Match system),
  so every window, sheet, menu and alert follows at once. The notch panel is always dark (black, like the
  hardware), whatever the setting.
- **Widget.** The setting is in the shared `settings.json`; the widget forces Light or Dark while it draws
  in full color, and leaves the colors to macOS in the tinted and dimmed desktop modes.
- **Glass.** Surface tints are `.glass` tokens: solid with Reduce Transparency or Increase Contrast, and
  hairlines get stronger with Increase Contrast.
- **The update.** `LightThemeMigration` runs once (recorded as `didMigrateLightTheme1` in the settings):
  it sets everyone to Light and moves Indigo, the old default, to Orange. Blue, Purple and Teal are kept.

## Cards from what you copy

With "Offer to make a card when I copy text" on, `CopyToCardService` looks at the clipboard once a second
(macOS has no notification for a copy; the timer may drift by half a second). It only compares a counter
until something new is copied. For a copy of text in another app (not FishBrain, and not marked
`org.nspasteboard.ConcealedType` or `TransientType`) that is a word or short phrase (at most 60 characters,
5 words, one line), `CopyOfferStore` shows an offer for 6 seconds on every display's notch; the same text
copied again within 8 seconds gets no second one. Clicking the offer, or pressing Control-Option-C (a
Carbon hot key, which needs no permission), opens `CardDraftEditor` in the open notch. Saving adds the card
to the end of the chosen deck through `DeckStore`, like any edit.

Recent macOS versions alert, or refuse, when an app reads the clipboard without a paste. When
`NSPasteboard.accessBehavior` isn't Always Allow, the service doesn't read the text at all: it offers
"Copied text" for any text copy and reads the clipboard only when the offer is clicked. Setting FishBrain to
Allow in System Settings > Privacy & Security > Paste from Other Apps shows the copied text on the offer.

## Sharing decks: CSV and Anki packages

Decks and subjects leave and enter the app as files, so nothing needs an account or a network.

- **Export** (`ExportSheet`, `LibraryExport`, `AnkiExport`): from a deck's or subject's menu, or File ▸
  Export… (⇧⌘E). `ExportDraft` is the pure description of what the sheet asks for (target, format,
  options, unticked decks) and why Export is off. CSV is `Front, Back` and, for subjects, `Deck, Subject`
  columns, UTF-8 with a byte-order mark. The Anki package is a legacy schema-11 collection, a `media` map
  and the pictures in a zip; each card is a Basic note, subjects become `A::B::C` decks, and GUIDs and deck
  ids come from the cards' and decks' own ids so a re-export matches in Anki.
- **Import** (`ImportSheet`, `CSVImport`, `AnkiImport`): File ▸ Import… (⇧⌘I), a subject's menu, the
  sidebar's + New menu, a file dropped on the window, or a file opened with FishBrain from Finder or
  AirDrop (`DeepLinkRouter.pendingImportURL`; the types are declared under `CFBundleDocumentTypes` in
  `project.yml`). Both formats produce a `CSVImportPlan` that the sheet previews and `DeckStore.performImport`
  applies as one undo step.
- **CSV** is read as records (`CSVRecords`), so a quoted field may hold line breaks; the separator, encoding
  and header row are detected, and the columns can be remapped. Subject paths in a `Subject` column are cut
  at `›`, `::` or `/`, three levels deep at most; anything deeper joins the deck's name.
- **Anki packages** are read with `ZipArchive` (stored and deflated entries, checksums, unsafe names refused,
  250 MB cap) and `SQLiteFile` (system SQLite). The legacy collection is read; the newer compressed
  `collection.anki21b` is recognised and refused. Basic notes come in as they are, "reversed" notes as one
  card, Cloze notes as one card per blank; other types are skipped and listed.
- Study progress is never exported or imported. The sandbox permission for files you choose is read-write
  (`project.yml`).

## Pictures on cards

A card can have one picture on each side (`frontImage`, `backImage` in `decks.json`: a file name and an
optional description for VoiceOver). The files are in an `Images` folder next to `decks.json`, so the
widget can read them. Adding a picture reads it with ImageIO (PNG, JPEG, HEIC, GIF first frame, TIFF,
BMP...), applies the camera's rotation, and stores a copy with the long edge at most 1600 px and a small
one at 400 px (`-thumb`) that the widget and notch use, to stay inside their memory limits. A picture
with transparency stays a PNG; anything else becomes a JPEG. After every save the app deletes picture
files no card uses (a deleted card or deck, a replaced picture); files younger than a minute are left
alone, so a picture just added isn't swept before its card is saved. The same sweep runs at launch, but
only when a library was loaded, so an unreadable `decks.json` never looks like "no card uses any".

`decks.json` is format version 2 or later because of this: an older build that opened it would save it
back without the pictures, so it refuses a newer version instead. Version 1 files load unchanged.

## Grading and reviews

After a card is turned over you can grade it Again, Hard, Good or Easy (in the notch, or in a medium or
large widget). `ReviewScheduler` (one function, so it can be swapped) is a simple SM-2-style scheme:

- **Learning** (a new card, or one you forgot): Again 1 min, Hard 10 min, Good 1 day, Easy 4 days. Good
  and Easy graduate it.
- **Reviewing**: Again starts it over (1 min, ease -0.2, a lapse); Hard multiplies the gap by 1.2
  (ease -0.15); Good by the card's ease (2.5 to start); Easy by ease x 1.3 (ease +0.15). Each grade is at
  least a day longer than the one below it. Ease never drops under 1.3 and gaps stop at 10 years.

Each card's due date, gap, ease, reviews and lapses are kept per deck in `playback.json`, next to the
skips and flips, not in `decks.json`: `decks.json` has one writer (the app, which holds the whole
library in memory), while the widget grades too, and `playback.json` already has locked
read-modify-write across processes.

`CardScheduler` shows graded cards that are due first, the most overdue first, and rotates among them
like it does through a deck. Which cards are due is judged at the start of the 5-minute slot, so the
app, notch and widget agree during a slot. With none due (and always, if you never grade) it is the
plain rotation through the whole deck. Grading moves straight on to the next card. A study session has
its own rotation and doesn't grade.

## Streak and daily goal

A card counts as studied when it is flipped to its answer, once per card per day, from the app, the
notch or a widget: all three go through `PlaybackActions.flip`, which also writes `study.json` next to
`playback.json`. Only today keeps card ids (to count each once); earlier days keep a count and whether
the goal was met, so the file stays small. The streak is the run of days with the goal met, ending
today or, while today is still open, yesterday. Days follow the Mac's current calendar and time zone.

## Study sessions

A session is a separate, short rotation that only the notch follows: cards change every 30 seconds
(`CardScheduler` with its slots counted from the moment the session starts, so the first card lasts a
full 30 seconds), with its own skips and flips kept in `session.json`. The widget and the main window
keep following the normal 5-minute rotation, which carries on untouched afterwards. Time left comes
from the start date, so a Mac that sleeps through the end shows the recap on wake. A card flipped to
its answer in a session counts toward the daily goal like any other flip.

## Editing in the Now showing preview

Double-click the text on the Now showing card to edit the side that is showing, right there. A single
click still flips the card; it waits out the system double-click interval (about a quarter of a second)
first, so a double click can call it off.

The rotation can't be paused: `CardScheduler` works out the live card from the clock, and the widget and
notch read the same state from the app group. So `PreviewCardEdit` holds the card in the preview only,
while the widget and notch carry on. Nothing in `playback.json` changes because of editing, and grading
and Skip are off until editing ends.

Only Save keeps an edit. It trims the text, refuses an empty front (an empty back is fine, as in the
table), and writes through `DeckStore.setText` as one undo step ("Edit Card"), changing nothing else on
the card. Esc or Cancel keeps the saved text. Anything else throws the draft away with no prompt: another
deck or a subject, Learn, a sprint, closing the window, quitting, clicking into the card table, or the
card being deleted. While editing, the card's row in the table shows the draft in the accent color.

The field is an `NSTextView` (`PreviewTextField`) so it can center its lines in the card's own font and
tell Return (save) from Shift+Return (new line); Esc cancels. Typing has its own undo inside the field.
Text only: pictures are still added and changed in the table.

## Accessibility

- **Keyboard**: New Deck (⌘N), New Subject (⇧⌘N), Add Card (⌥⌘N), Find Cards (⌘F), all in the menus; Up and Down move between
  decks in the sidebar; Return in a card's Front moves to its Back.
- **VoiceOver**: every control is labeled, decorative icons are hidden, deck rows read "Everyday Spanish,
  48 cards", and card faces read the front, or "Answer, ..." once flipped, in the app, the widgets and the
  notch. The notch can't be hovered with VoiceOver, so its resting state is a button ("Everyday Spanish,
  card 12 of 48") whose action opens it, and the open card has a "Close card" action.
- **Editing the Now showing card without a double click**: Tab to the card (with Full Keyboard Access),
  then Return edits the side showing and Space flips; VoiceOver has an **Edit card** action next to the
  flip; the right-click menu has Flip and Edit Front or Edit Back. The field reads "Front, text field" or
  "Back, text field", and VoiceOver hears "Saved" or "Cancelled" when editing ends.
- **Reduce Motion**: the notch flip becomes a crossfade and the notch no longer springs open.
- **Contrast**: text meets WCAG AA (4.5:1) in light (with every accent) and dark; `DesignTokensTests` checks every text and
  surface pair, and a lint fails if an icon has no label.
- `-FishBrainPrintAccessibility` (Debug) prints the notch's accessibility tree, resting and open.
