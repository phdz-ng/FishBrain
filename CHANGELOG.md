# Changelog

## 1.0

The first release: flashcards that come to you, on the desktop and in the notch.

- **Desktop widget** in small, medium and large sizes. Shows one card at a time and moves to the next
  every 5 minutes. Click to flip, skip to move on, and pick a deck per widget (right-click the widget,
  Edit Widget).
- **Notch display** on Macs with a notch: move the pointer to the notch to open the current card, with a
  countdown to the next one. Choose which deck it shows, or turn it off with Show in notch.
- **Decks and cards**: create, rename, color and delete decks; add, edit and delete cards; find cards
  across all decks (⌘F); keyboard shortcuts for New Deck (⌘N) and Add Card (⇧⌘N).
- **Bulk import**: paste a list (one card per line, front and back separated by a comma or a tab) or
  import a .csv, .tsv or .txt file.
- **Getting Started deck** and a welcome sheet on first launch, explaining how to add the widget
  (right-click the desktop, Edit Widgets).
- **Accent colors** (purple or teal) and a Frosted Midnight app icon.
- **Accessibility**: VoiceOver labels and actions, full keyboard navigation, and Reduce Motion.
- **Open a CSV or Anki package straight into FishBrain.** Double-click a .csv, .tsv or .apkg, choose Open
  With ▸ FishBrain, or accept one by AirDrop: FishBrain opens on the Import sheet with that file. FishBrain
  doesn't take these files over from Numbers, Excel or Anki; it is only offered. **Import…** is also at the
  bottom of the sidebar's **+ New** menu (⇧⌘I), a file dropped on the window now takes .apkg too, **File ▸
  Export…** is dimmed while there is nothing to export, and the deck page's menu item is now **Import…**
  (it was "Import CSV").
- **Export as an Anki package (.apkg).** In the Export sheet the **Anki package** card is on now. Every card
  becomes a Basic note (Front and Back); a subject's decks are nested like "Spanish::Grammar::Verbs"
  (starting at the subject you export; one deck is just its name), with parent decks written too. Pictures
  go in with their descriptions, and text is escaped with line breaks kept. Untick decks to leave them out;
  the sheet shows about how big the file will be. Study progress and deck colors aren't included. Cards keep
  the same Anki identity every time you export them, so importing a newer export into Anki updates the
  cards instead of duplicating them. FishBrain's own Import reads the package back to the same subjects,
  decks, text and pictures.
- **Import an Anki package (.apkg).** Choose or drop an Anki deck package in the same Import sheet. It
  shows the decks inside (tick the ones you want), how each note type comes in, and how many pictures and
  sounds there are. A deck with decks inside becomes a subject; "Spanish::Grammar::Verbs" makes Spanish >
  Grammar > Verbs, up to three levels, and you can file the lot inside a subject you choose. Basic notes
  come in as they are, a "Basic (and reversed card)" note as one card (front to back), and a Cloze note as one
  card per blank, with […] on the front and the whole sentence on the back. HTML is flattened to plain text
  (line breaks stay). One picture per side is kept and extra ones are listed in the report; sounds, study
  progress and note types FishBrain can't use (like Image Occlusion) are skipped and listed. Packages written
  in Anki's newer compressed format say so, with how to export an older one. The import is one undo step.
- **Import CSV with a preview, and make decks and subjects from it.** **File ▸ Import…** (⇧⌘I), a subject's
  ⋯ menu or right-click > **Import…**, **Add ▸ Import CSV** on a deck, or dropping a .csv, .tsv or .txt file
  on the window opens one sheet. It finds the separator (comma, semicolon or tab), the encoding and whether
  the first row is a header, and shows which column is the front, the back, the deck and the subject, which
  you can change. A preview lists the first rows with where each goes, and marks any that will be skipped
  and why. Then choose: **make decks and subjects from the file** (a Subject column like
  "Spanish › Grammar" makes the nesting, up to three levels, and anything deeper joins the deck's name),
  **add everything to one deck**, or **add to a new deck**; and optionally skip cards already in the deck.
  The whole import is one undo step, and the result screen lists what was made, which rows were skipped,
  and opens it for you. A file with only one column, or one that can't be read, says so instead of
  importing nothing.
- **Export a deck or subject as CSV.** **Export…** is in the right-click menu of a deck or a subject in the
  sidebar, in a subject page's ⋯ menu, in a new ⋯ menu on a deck page, and in File ▸ Export… (⇧⌘E) for what
  is open (the whole library when nothing is). Choose a comma, semicolon or tab separator, a header row, and
  for one deck whether to add Deck and Subject columns. A subject (or the library) is one file with
  `Front, Back, Deck, Subject` columns, the subject written as a path like "Spanish › Grammar", and you can
  untick decks to leave out. The file is UTF-8 with a byte-order mark so Excel shows accents. Pictures can't
  go in a CSV, and the sheet says how many are left out. Study progress is never written. When it's saved,
  **Show in Finder** and **Share…** are one click away. Importing reads CSV as records now, so a card whose
  text has a line break survives a round trip, and a semicolon-separated file (what European Excel writes) is
  recognised. FishBrain can now save files you choose, so the sandbox permission for chosen files is
  read-write.
- **Learn all and Review… for a whole subject.** A subject's page has **Learn all**, which goes through
  every card in every deck inside it (sub-subjects too) one deck after another in the order the sidebar
  lists them, with the deck's name quietly under the title and S shuffling across decks, and
  **Review…**, which opens the sprint sheet with every deck inside it ticked. The tiles for the subjects
  inside have Learn and Review as the deck tiles do. An empty subject turns both buttons off and says
  why. Like Learn, flipping counts toward your goal and changes no schedule.
- **Mix subjects and decks in a Review sprint.** The setup sheet lists your library as a tree (all three
  levels), each row with what is due or "Caught up". Ticking a subject ticks every deck inside it (a dash
  shows some of them are), and shortcut chips tick **This deck**, the subject you have open, **Everything
  due** or clear them. ⌘-click and Shift-click choose several decks or subjects in the sidebar without
  changing the page you are on, and **Review N decks** opens the sheet with them ticked. The last mix is
  remembered until you quit.
- **Tell decks with the same name apart.** Search results show where a deck is, under the card
  ("Spanish › Grammar › Verbs › Regular verbs"). The notch's deck picker groups decks under their subject,
  with loose decks last. The widget's Choose Deck list shows the subject as a subtitle, so two decks called
  "Verbs" in different subjects are easy to pick between (widgets you already set up keep their deck). The
  cards and headers themselves still show just the deck's name.
- **Move, drag and delete subjects and decks.** Drag a deck or a subject in the sidebar onto a subject to
  file it, onto **Decks** to make a deck loose, or onto **Subjects** to make a subject top level. Targets
  light up, and a drop that wouldn't work (into itself, into what it holds, or a fourth level) shows why
  and the pointer says no. Right-click **Move to…** lists only the places that work. Deleting a subject
  asks what to do with what is inside: **Move its contents up** (the default), or delete it with its
  decks and cards. Deleting the subject you have open selects its parent. **Undo (⌘Z)** puts back the
  last move or delete of a deck or subject, with its cards and pictures.
- **Subjects in the sidebar, and a page for each.** Decks can be grouped under subjects (up to three
  levels). The sidebar has **Subjects** (open or close them with the arrow, or Right and Left) and
  **Decks** (loose ones), and never goes more than one indent deep: a subject inside a subject opens as
  its own page, with a breadcrumb back up, and the sidebar marks the nearest row it can show. Each
  subject page has tiles for the subjects and decks inside it with a bar of mastered, young, learning
  and new cards, "9 due · 22 mastered · 12 new", and Learn and Review on each deck. **+ New** is now a
  menu: New Deck, New Subject (⇧⌘N), and New Deck or New Subject in the subject you are in. **Add Card
  moved from ⇧⌘N to ⌥⌘N** to make room.
- **The notch and a Review sprint share one clock.** While a sprint runs, a drawn notch's pill shows the same
  ring, time left and "N reviewed" a session does (VoiceOver: "Review sprint, 7:42 left, 17 cards reviewed"),
  and the open notch shows "Sprint · 7:42 left · 17 reviewed" with **Go to sprint** in place of Start
  session; the notch keeps its own card rotation. Only one study clock runs at a time: starting a sprint
  during a notch session asks first ("12:40 left, 8 cards reviewed. Starting a sprint ends it and keeps its
  8 cards."), with Keep session or End it, start sprint. A finished sprint leaves the same recap and "Last: N
  cards" as a session. Quitting FishBrain ends a sprint and saves it.
- **Sprint history.** FishBrain remembers your last 100 Review sprints (in `runs.json`, next to your study
  log; your decks file is not touched). Once you have three sprints of at least three minutes, the setup
  sheet says "About 21 cards at your usual 2.1 a minute", and the results show "Your usual pace" (the
  median of your last ten) and "Last sprint". A sprint you end early is saved with the time it really ran.
  There is no "best" per mix, because mixes differ.
- **Review sprint.** Click **Review** in a deck's header, tick the decks to mix (each shows how many are
  due, or "Caught up"), choose 5, 10, 15, 25 minutes or your own length (the last one is remembered), and
  which cards: due first then new, due only, or everything shuffled. "Shuffle between decks" makes decks take
  turns. Start 10:00 opens a full-window sprint: how many you have reviewed, the time left, how many due cards
  are left, a fish riding the clock, the card (Space turns it over) and four large grade buttons with their
  gaps. Keys 1 to 4 grade, Space after turning the card grades Good, P pauses (and blurs the card), Esc asks
  before ending. A card you grade Again comes back a few cards later. When the clock reaches 0:00 the card
  on screen can still be graded. The results show the count and pace, how many you remembered, how the grades
  fell, today's goal and streak, a split by deck and the cards that came up again, with **Review the missed**
  (one minute on just those), **Same mix again** and **Done**. The widget and notch rotation don't move
  during a sprint, and the time left is announced to VoiceOver at 1 minute, 30 seconds and 0.
- **Learn mode.** Click **Learn** in a deck's header to go through it one card at a time, with just the
  card on screen: click it or press Space to flip, the arrow keys (or the round buttons) to move, S to
  shuffle, Esc or Leave Learn to go back. A small fish swims along the bottom as you get through the
  deck, and "Round complete" offers Go again or Leave after the last card. There are no grades and no
  timer; turning a card to its answer counts toward today's goal and streak, once per card per day, and
  nothing about a card's review or what the widget and notch show changes. With Reduce Motion the flip is
  a cross-fade and the fish steps.
- **Grade cards in the deck view.** Under the Now showing card are Again, Hard, Good and Easy, each with
  when the card would come back ("1 min", "7 days"). They are dimmed until you turn the card over, then
  grading moves on to the next card, and the notch and widgets agree. There are no 1 to 4 keys in the main
  window (they would fight with typing); the buttons work with Tab and VoiceOver ("Good, next in 15 days").
  The card list has a Status column: New, Learning · 10 min, Due now, In 4 days, Mastered · 3 mo (next
  review 21 days or more away). Under the panel is today's count and streak. The deck's toolbar has Learn
  and Review buttons (disabled for now) and one Add menu holding Add Card, Paste Cards, Import CSV and
  Generate…. The Now showing panel is 280 pt wide, and in a short window its card gets shorter.
- **Subjects, underneath.** The library file can now hold subjects: groups of decks (and of other
  subjects, up to three levels) that decks are filed under. Nothing in the app shows them yet. **Library
  files now use format 3**, so an older FishBrain won't open a library written by this one. Older files
  open unchanged, and a damaged subject tree is repaired when it is read, without dropping any deck or card.
- **Notch on every display.** Macs without a notch get a notch FishBrain draws in the menu bar, and a
  new switch in Settings shows it on external monitors too. Also in Settings: hide it while an app is
  full screen (or the menu bar is hidden), and show it only on the display you are working on.
- **What the pill shows.** A new setting with a preview and a one-line explanation per style. Only
  a real notch always shows Classic.
- **Swimming fish.** A pill style where a small fish swims across the notch while a card lasts; when it
  reaches the end, the next card arrives. With Reduce Motion it moves in steps.
- **Streak and daily goal.** A card counts as studied when you flip it to its answer (in the app, the
  notch or a widget), once a day. Set a daily goal in Settings (10, 20, 30 or 50 cards); days you
  reach it make a streak. The open notch shows "18 of 30 today · 12-day streak", and a new pill style
  shows your streak, this week and today's count.
- **Study session.** Open the notch and press Start session (5, 10, 15 or 25 minutes): cards change every
  30 seconds, a drawn notch shows a ring with the time left and how many cards you reviewed, and a short
  recap appears at the end ("22 cards in 15 min"). The widget's rotation is left alone.
- **Grade your cards.** Turn a card over in the notch or in a medium or large widget and choose Again,
  Hard, Good or Easy, each showing when the card will come back ("1 min", "10 min", "1 day", "4 days").
  Cards that come due are shown first, the most overdue first, and the deck view says how many are due.
  If you never grade, nothing changes. An optional setting lets keys 1 to 4 grade in the open notch.
- **Pictures on cards.** Add one picture to the front or back of a card: drop a picture file on it, use
  the picture button that appears when you hover a row (Choose Picture or Paste Picture), or press
  Shift-Command-V with the clipboard holding a picture. Click a thumbnail to describe it for VoiceOver,
  replace it or remove it. Pictures show in the app, the notch and the widget. Search finds the
  description. Pictures are scaled down on import, and ones no card uses any more are deleted.
  **Library files now use format 2**, so an older FishBrain won't open a library written by this one.
- **Cards from what you copy.** Turn on "Offer to make a card when I copy text" in Settings and, after
  you copy a word or short phrase in another app, the notch offers "+ Make a card". Click it (or press
  Control-Option-C) to open a small editor right in the notch: the copied text is the front, you type the
  back, pick the deck, and press Return. Off by default; secret copies from password managers are never
  offered.
- **AI settings.** Settings now has General, Notch and AI tabs. In AI, add an Anthropic or OpenAI API key
  (kept in the macOS Keychain, checked as soon as you paste it), see which models it can use, pick one,
  and choose which company makes cards. Prices are shown as estimates with the date they were last
  checked. FishBrain can now go online, for this only: your key is only ever sent to the company it
  belongs to. Nothing is sent until you use Create with AI.
- **Create with AI.** A new row above your decks (or File > Create with AI, Shift-Command-A) opens one screen
  for making a deck with AI: drop, paste or choose PDFs, pictures and text files, say what matters to you,
  pick how many cards, their style and language, and where they go. Every file shows as a chip, and one that
  is too big says so (a PDF over 600 pages lets you choose which pages). Next to Generate you see which model
  will be used and an estimated cost. If you keep "Show an estimated cost" on with an Anthropic key, what you
  add is sent to Anthropic to be counted before you press Generate.
- **Watch the cards arrive, then fix them before saving.** Press Generate and the deck's suggested name appears,
  then the cards one by one (the sidebar says 9/20, then Draft). Stop keeps the finished ones. Edit any card,
  untick the ones you don't want, write a new one with ↻, add your own, or type what you'd change in "Refine all
  cards" ("make the answers shorter", "add 5 more on the Krebs cycle"). Then Save as new deck, or Add to deck.
  Nothing is saved until you do; leaving the screen keeps the draft, and quitting asks before throwing it away.
  After a run you see what it cost, as an estimate with the date the prices were checked.
- **Generate… inside a deck.** A deck's toolbar has a Generate… button that opens Create with AI with the cards going
  into that deck. The deck's own name stays, FishBrain tells the model which cards the deck already has so it
  doesn't repeat them, and the button to save reads Add to "Spanish A2". It is dimmed, with a tip, until you have
  set up an AI provider.
- **Apple Intelligence, on your Mac.** On a Mac with macOS 26 or later and Apple Intelligence turned on, Settings > AI has a third
  choice that makes cards for free, with nothing leaving your Mac and no key. It reads text, PDFs that have selectable text
  (scanned pages need Anthropic or OpenAI), and, on macOS 27, pictures. It is a smaller model, so long material is cut into parts
  (and a very long one is cut short, which FishBrain tells you), and without notes or a PDF it can get facts wrong. It is only used
  when you choose it.
- Your library is stored on your Mac in `~/Library/Application Support/FishBrain` (or the app group
  container for signed builds). Nothing is sent anywhere unless you use Create with AI, which sends the material you choose
  only to the provider you pick (Anthropic or OpenAI), or Apple Intelligence, which stays on your Mac.

Requires macOS 14 or later.
