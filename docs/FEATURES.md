# How the features work

Notes on copy to card, sharing decks, pictures, grading and reviews, the streak and accessibility. Back to the [README](../README.md).

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

## Accessibility

- **Keyboard**: New Deck (⌘N), New Subject (⇧⌘N), Add Card (⌥⌘N), Find Cards (⌘F), all in the menus; Up and Down move between
  decks in the sidebar; Return in a card's Front moves to its Back.
- **VoiceOver**: every control is labeled, decorative icons are hidden, deck rows read "Everyday Spanish,
  48 cards", and card faces read the front, or "Answer, ..." once flipped, in the app, the widgets and the
  notch. The notch can't be hovered with VoiceOver, so its resting state is a button ("Everyday Spanish,
  card 12 of 48") whose action opens it, and the open card has a "Close card" action.
- **Reduce Motion**: the notch flip becomes a crossfade and the notch no longer springs open.
- **Contrast**: text meets WCAG AA (4.5:1) in the dark theme; `DesignTokensTests` checks every text and
  surface pair, and a lint fails if an icon has no label.
- `-FishBrainPrintAccessibility` (Debug) prints the notch's accessibility tree, resting and open.
