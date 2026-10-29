# QA pass (FLAS-33)

Run on a MacBook with a notch (Mac17,4, M5, macOS 27.0.1) by an automated session with no screen
or input access. "Checked" means measured or covered by a test; "To do by hand" needs a person,
another Mac or another display.

## Checked

| Item | Result |
| --- | --- |
| Idle cost of the notch | A collapsed notch has no timers and no polling. The next-card timer fires once per 5 minutes. Open, the countdown ticks once a second, and only while open. |
| Idle cost of the main window | Polled the playback file once a second for as long as the window existed (~1.3 wakeups/s measured on the old build while it was open). Replaced by the folder watcher the notch already uses, plus a re-read when the app is activated. What remains while the window is visible is its on-screen countdown (call stacks sampled: `TimelineView` in `NowShowingPanel`), about 1 wakeup/s and ~0.7% CPU in a Debug build. |
| Sleep/wake, clock and time zone changes | The notch's timer was set against the old time. It now refreshes on wake, `NSSystemClockDidChange` and `NSSystemTimeZoneDidChange` (`NotchWakeTests`). The widget builds its timeline from the clock each time it reloads. |
| 5,000-card deck | Save and load < 2 s (measured 16 ms), search across 10,000 cards < 1 s (75 ms), picking the current card for a day of rotations < 0.5 s (5 ms), parsing a 5,000-line paste < 1 s (10 ms). The card list is a `List` (lazy) and search results a `LazyVStack`. |
| Long card text (~39,000 characters) | Renders at all three card sizes in well under a second (`ScaleTests`); text shrinks to its minimum scale factor, then is cut off. |
| Light and dark | Colors come from tokens that have both appearances; a lint test forbids hard-coded colors in views. |

## To do by hand

- [ ] Non-notched Mac: the notch is not drawn (placement returns nil without a notch); the app and widget work as normal.
- [ ] External display alone, and notch + external display: the notch stays on the built-in display after plugging and unplugging (`didChangeScreenParameters` repositions it).
- [ ] Light and dark wallpapers: widget and notch card are legible on both.
- [ ] Full-screen apps and several Spaces: the notch strip stays on top and does not steal clicks.
- [ ] A real night of sleep: the widget and notch show the right card after wake, and the widget has no gap.
- [ ] Widget with a 1,000+ card deck and a card with very long text, in small, medium and large sizes.
- [ ] Activity Monitor, Energy tab, app idle with the window closed: Energy Impact near 0, "Idle Wake Ups" near 0.
- [ ] Welcome sheet, Help menu, app icon in the Dock/Finder/Launchpad (from FLAS-32).

## Notch on every display (FLAS-36), to check by hand

Not covered by unit tests, because it needs real displays:

- Mac without a notch: the drawn pill is exactly as tall as the menu bar and sits in the middle.
- External monitor: off by default; Settings > Show on external displays adds it, and unplugging and
  replugging the monitor brings it back.
- Full-screen app on one display hides the pill on that display only; leaving full screen shows it
  again (it can take about a second). Turning "Hide when an app is full screen" off keeps it.
- "Only on the display with the active menu bar": click into a window on the other display and the
  pill moves there.
- A Mac with only monitors (Mac mini, or a laptop with the lid closed) still shows it on the primary one.
- A real notch still shows the camera layout and ignores the full-screen rule.
- Idle CPU with two displays enabled is still near zero in Activity Monitor.

## Pill style (FLAS-37), to check by hand

- Settings > Notch > What the pill shows lists the styles with an explanation each, and the preview is
  a drawn pill with the deck icon and position.
- The note says a real notch always shows Classic. On a Mac with only a notched display (no drawn
  notch on screen) it also says the choice applies when one appears.
- Plug in a monitor with "Show on external displays" on: the note loses the extra sentence.
- VoiceOver reads each option's name and explanation and says which one is selected.

## Swimming fish (FLAS-38), to check by hand

- Settings > Notch > What the pill shows > Swimming fish: the drawn pill widens and shows the deck icon,
  a fish on a dashed line, and the position. The fish is at the left right after a card arrives and at
  the right just before the next one (the 5-minute slot; at 2:30 left it is in the middle).
- When the card changes the fish fades out at the right and a new one fades in at the left. It never
  swims back across the pill.
- The tail flicks every few seconds. With Reduce Motion on (System Settings > Accessibility > Display)
  it does not flick and the fish moves in steps about every 15 seconds.
- Sleep the Mac for several minutes and wake it: the fish is where the clock says it should be.
- Open the notch (hover): nothing at rest keeps redrawing behind the open card.
- **Idle energy:** with the fish on, Activity Monitor's Energy tab shows FishBrain's idle impact near
  zero, like with Classic (target from FLAS-33). The fish redraws every 5 seconds, not per frame.
- A real notch ignores the style and keeps Classic.

## Streak and daily goal (FLAS-39), to check by hand

- Settings > Study > Daily goal offers 10, 20, 30 and 50 (default 20).
- Open the notch and flip a card: the line under the countdown reads "1 of 20 today". Flip the same card
  again later the same day: the count doesn't change. A new card counts.
- Flip a card from a widget: the notch's count goes up too (within a moment).
- Streak pill (drawn notch only): the flame with "Start a streak" before any streak, then "1 day",
  "2 days"...; seven dots for this week (filled = goal met, ring = today); "N / 20 today".
- Reach the goal with the pill showing: today's dot fills with a short glow. With Reduce Motion on there
  is no growing or pulsing, the dot just fills.
- Change the goal to something already reached: today fills at once. Change the date to tomorrow without
  studying: the streak is kept; skip another day: it resets to "Start a streak".
- VoiceOver reads the streak pill as "12-day streak, 18 of 30 cards today".
- Midnight (or changing the Mac's date) starts a new day in the pill within a moment.

## Study session (FLAS-40), to check by hand

- Open the notch: "Start session" and a length button (15 min; each press goes 5, 10, 15, 25) sit
  bottom right. Choose Study session as the pill style and they move up under the header.
- Start: the card stays, the countdown becomes 30 seconds and a new card arrives every 30 seconds.
  The widget keeps its own 5-minute rotation.
- Drawn notch at rest during a session, whatever style is chosen: a ring, the time left (9:18), a
  separator and "14 reviewed". Flip cards from the open notch and the number goes up (each card once).
  With several displays all show the same session.
- A real notch keeps its normal resting look; the open card shows "6:18 left · 3 reviewed" and End session.
- End session, or let the time run out: the pill shows "22 cards in 15 min" for about 8 seconds, then the
  chosen style and the normal rotation return. Ending early says how long it ran.
- With Study session chosen as the style and no session running, the pill reads "Last: 22 cards", or
  "Start a session" the first time.
- Sleep the Mac past the end and wake it: the recap shows, not a stale timer.
- Reduce Motion: the ring steps instead of gliding.
- Cards flipped in the session raise today's count and can complete the daily goal.
- Quit and reopen mid-session: it carries on with the right time left.

## Grading cards (FLAS-41), to check by hand

- Open the notch and flip a card: Again / Hard / Good / Easy replace the countdown, each with a gap
  ("1 min", "10 min", "1 day", "4 days" for a new card). The card doesn't change size when it flips.
- Press Good: the next card comes up question side up. In the main window the deck subtitle gains
  "N due" once graded cards come due (it updates about every minute).
- Grade a card Again: within about 5 minutes (the next slot) it comes back before the others.
- Flip a card in a medium or large widget: the same four buttons appear under it and work without
  opening the app. The small widget has no grade buttons.
- Never grade anything: the rotation is exactly as before.
- During a study session there are no grade buttons.
- Settings > Study > "Grade with the keyboard" (off by default): with it on, flipping a card in the open
  notch makes it take the keyboard, 1 to 4 grade, and typing in the app behind works again once the card
  is graded, the notch is closed, or you click elsewhere. **Check this carefully on a real Mac**: it
  couldn't be tried in tests, and with the setting off the notch must never take focus.

## Pictures on cards (FLAS-42), to check by hand

- Hover a card row: a small picture button appears on each side. Choose Picture opens a file panel
  (PNG, JPEG, HEIC, GIF, TIFF); the picture becomes a thumbnail in that side's field.
- Drag a picture file from Finder onto a side: it is added. Drag a PDF or text file: an alert says it
  isn't a picture.
- Copy a picture (a screenshot, or a file in Finder), put the cursor in a Front or Back field and press
  Shift-Command-V (Edit > Paste Picture): it is added. (Plain Command-V is greyed out for a picture
  while a text field is being edited, which is why there is a separate command.)
- Click a thumbnail: a popover has a Description for VoiceOver field, Replace and Remove. Replacing or
  removing deletes the old files within a moment of the next save (check
  `~/Library/Application Support/FishBrain/Images`).
- The picture shows above the text in the Now showing panel, the notch (open) and a widget; a picture
  with no text is shown alone. Flip, skip and rotation work as for any card.
- **Widgets with several picture cards**: leave a medium and a large widget on a deck of picture cards for
  a while and check they keep updating and don't blank out (the widget only loads the small copies).
- A very big photo (12 MP) is added quickly and the Images folder shows a file of at most 1600 px.
- Delete a card with a picture, and a deck with pictures: their files disappear (about a minute later,
  or on the next launch).
- Search for words from a picture's description: the card is found.
- VoiceOver on a picture card reads the text and "picture: <description>".
- The library file is format 2: an older FishBrain build refuses to open it.

## Cards from what you copy (FLAS-43), to check by hand

- Settings > Cards from what you copy: the switch is off by default. Turn it on.
- Copy a word or short phrase in another app (Safari, Notes). On a Mac without a notch the pill reads
  `Copied "sin embargo"` with a `+ Make a card` button; on a real notch the strip beside the camera shows a
  `+ Card` chip. It goes away after about 6 seconds. Hovering it doesn't open the study card over it; clicking it does what the offer says.
- Copy a sentence (over 5 words or 60 characters), several lines, or a password from a password manager:
  no offer. Copy inside FishBrain's own window: no offer. Copy the same word again straight away: no
  second offer.
- **Clipboard permission.** On recent macOS, with FishBrain not set to Allow under System Settings >
  Privacy & Security > Paste from Other Apps, the offer says "Copied text" for *any* text copy and reads
  the clipboard only on click (macOS may then ask). Set it to Allow and the offer shows the copied text,
  and long copies are ignored. **Check what macOS actually does here**: it couldn't be tried in tests.
- Click the offer: the notch opens with New card, a deck menu (the notch's deck), the Front already filled
  and the cursor in the Back. Type, press Return: "Added to <deck>" shows for a moment and the card is at
  the end of the deck (widgets refresh). Escape or Cancel closes without adding. The notch stays open
  while you type, and the app you were in gets its keyboard back afterwards (**check typing works there
  again**).
- Control-Option-C (with the notch showing) opens the editor on whatever is on the clipboard, even if
  the offer is gone. Check it doesn't clash with another app's shortcut.
- Turn the setting off: no offers, the shortcut stops working, and Activity Monitor shows FishBrain's idle
  wake-ups drop back (the once-a-second look only runs while the setting is on).
- VoiceOver announces the offer when it appears.

## AI settings (FLAS-45), to check by hand

- Settings now has three tabs (General, Notch, AI) and each page scrolls if it is taller than the window.
- AI tab, with no keys: both providers say "No key" and have a key field. Paste an Anthropic key: it is
  checked at once, the status goes Checking... then "✓ Works", the field turns into `sk-ant-•••xxxx`
  with Remove, the model menu fills in (Claude Opus 5.5 chosen, marked Recommended) and Anthropic becomes
  the one "In use". A wrong key says "This key was rejected"; turn Wi-Fi off and press the refresh arrow:
  "No network connection", and the model menu still works.
- Same for OpenAI: the menu shows only likely chat models, and Show all models adds the rest.
- The price under the model reads `$4 / $20 per million tokens (estimate · prices updated 8 Oct 2026)`
  (in your own date format), with a tooltip; the line under both providers gives the date again and where
  the real prices are. A model not in the list says "price not known".
- Open Keychain Access and find `com.fishbrain.ai.anthropic`: the key is there and nowhere else. Remove the
  key in Settings: the entry is gone.
- Leave Settings closed for over a day and reopen the AI tab: the models are asked for again.
- Cards per run and the cost-estimate switch are saved.
- The widget still works with the network off (it never goes online).
- **First launch after this build** on a Mac that has never run the app with network access: the sandbox
  now allows outgoing connections, so nothing should prompt; check the Keychain doesn't ask for a password.

## Create with AI composer (FLAS-49), to check by hand

A Debug build can show the screen without a key: launch with `-FishBrainSampleData -FishBrainSampleAI` (a
pretend Anthropic key and model, and a made-up cost; nothing is sent), plus `-FishBrainShowComposer` to open it
at launch and `-FishBrainSampleSources` to preload a PDF, a PDF of 840 pages, a picture and 1,240 words of text.

- The sidebar has a **Create with AI** row (sparkle) above Decks. Click it, or use File > Create with AI
  (Shift-Command-A): the content area shows the form; the row is filled with the accent. Pick a deck and come
  back: everything you had entered is still there.
- Add material three ways: drop files from Finder (the drop box lights up), Choose Files..., and paste. With
  the box selected (it is when the screen opens), Command-V adds copied files, a copied picture or copied
  text; with the cursor in "What matters to you", Command-V pastes into that field instead. The Paste button
  does the same from the clipboard, and says so when the clipboard has nothing to use.
- Try a PDF, a PNG, a HEIC, a WebP, a GIF, a .txt and a .md file. Each becomes a chip with an icon or
  thumbnail, its name, pages or size, and a cross. Pasted text reads "Pasted text / 1,240 words".
- A password-protected PDF, a file of another kind, and an empty text file each give a short message under the
  chips (OK dismisses it), and no chip.
- A PDF over 600 pages: its chip gets a red outline, "This PDF has 840 pages. Choose up to 600." and Choose
  pages... Pick 1 to 600: the chip reads "Pages 1-600 of 840", the message goes, and Use All Pages (right-click
  the chip) brings it back. Typing pages that aren't there, or more than allowed, says so and disables the button.
- Many big files together: the biggest chip says it is too much to send at once.
- Generate is dimmed until there is a chip or something in "What matters to you" (text in that field alone is
  enough). Hover it for why.
- How many cards: 10, 20, 30, 50, or Custom with a stepper (1 to 100); it starts from Settings > AI > Cards per
  run, and 25 in Settings shows as Custom 25. Card style, language and "Put cards in" (new deck, or any deck)
  change what is asked for.
- Generate row: the provider and model ("Claude Opus 5.5 - your Anthropic key"), Change... opens Settings on
  the AI tab, and a cost line "about $0.xx (estimate - prices updated ...)" that appears a moment after you stop
  changing things, with the tooltip. It is gone when the cost switch in Settings is off or the model's price
  isn't known. With an Anthropic key the material is sent to Anthropic to be counted (the switch's text says so).
- With no key: the Generate row says "Set up an AI provider to start" with a button that opens Settings on the AI tab.
- A model that can't read pictures (choose one in Settings) puts a message on each picture chip.
- Pressing Generate starts the run (see the next section).
- Tab reaches every control; VoiceOver reads each chip as "name, size", and the options by their names.

## Generating and review (FLAS-50), to check by hand

A Debug build can show it without a key: `-FishBrainSampleData -FishBrainSampleAI -FishBrainShowComposer
-FishBrainSampleDraft` starts a run at launch with a pretend provider (a card every 0.7 seconds; a refine
shortens the answers and adds a card; nothing goes online).

- **Generating:** the deck name appears first with a "suggested name" tag, then cards one at a time with a short
  fade (none with Reduce Motion on), and grey rows wait for the rest. The line above reads "Writing cards 9 of
  20" with a bar and the model name; with a PDF it starts "Reading 24 pages..." and becomes "Read 24 pages".
  The sidebar row says 9/20 while it runs and "Draft" after. Leave for a deck and come back: the draft is still
  there, and still running.
- **Stop** keeps the finished cards and says "Stopped at 9 of 20" with "Add 11 more". "Got 17 of 20" and "Add 3
  more" appear the same way when the model gave fewer than asked.
- Edit a card's front or back while others are still arriving: the edit stays. Save is dimmed until the cards
  have finished.
- **Review:** untick cards (they dim); the header checkbox ticks everything, or clears it when all are ticked;
  the footer says "19 of 20 selected". Page chips ("p. 166") show where a card came from. Click the deck name to
  rename it (the tag goes), click the icon for a color, and "Add a card yourself" adds an empty card with the
  cursor in it.
- **Refine all cards:** type "make the answers shorter" and press Return: the cards change, changed ones flash
  for a moment, and new ones say "added". A card you edited by hand is left alone unless you ask about it. A name
  you wrote is kept.
- **↻** on a card writes one new card for the same page; it replaces that card in place and keeps its tick. Only
  one thing runs at a time (↻, refine and Stop are dimmed or busy while it does).
- **Errors** show as one banner with what to do: Open Settings (bad key, model gone, out of credit: it also asks
  for the model list again), Try again, Add N more (cut off), Start over (refused, too big). A failed refine or
  ↻ leaves the cards as they were.
- **Cost:** after a run, "This run cost about $0.23 (estimate - prices updated ...)" with the tooltip; refines and
  ↻ add to it ("These runs cost"). Gone when the model's price isn't known.
- **Save as new deck** makes the deck with the ticked cards in order and selects it in the sidebar; **Add to
  deck** adds them to the end of a deck you pick. Check the widget and notch pick the new deck up. If you chose a
  deck in "Put cards in", Add to deck is the highlighted button.
- **Start over** (asks first) returns to the form with what you had added; **Discard** (asks first) empties it.
- Quit with a draft that has cards (or is still running): FishBrain asks before discarding it. Close the window
  instead: the draft is still there when you reopen it.

## Generate… inside a deck (FLAS-51), to check by hand

A Debug build: `-FishBrainSampleData -FishBrainSampleAI` has a pretend key, so the button is live;
`-FishBrainSampleDraftInDeck` (with `-FishBrainShowComposer`) runs a sample draft for the first deck.

- A deck's **Add** menu has **✦ Generate…** after Import CSV (FLAS-56 moved it there from the toolbar).
- Click it: Create with AI opens with "Put cards in" set to that deck. Anything already in the form (focus text,
  chips, style) is still there.
- With no key in Settings > AI the button is dimmed; hover it for "Set up an AI provider in Settings > AI first."
  With a draft waiting in Create with AI it is dimmed too ("Save or discard the draft in Create with AI first.").
- Press Generate: the screen shows the deck's own name and color (no suggested name, no color picker, tagged
  "adding to this deck"). The model is told the deck's cards so it doesn't repeat them: try a deck with a few
  cards and check none come back twice. A deck of more than 300 cards sends only its last 300 fronts.
- The primary button reads **Add to "Spanish A2"** and adds the ticked cards to the end of that deck and selects it
  (the widget and notch pick them up). "Add to another deck" lists the others; there is no "Save as new deck" for a
  draft made for a deck (Start over and choose a new deck in the form for that).
- Delete the deck while its draft is open, then press Add: nothing is lost, and the draft can still be saved as a
  new deck with that name.

## Apple Intelligence, on device (FLAS-52), to check by hand

Needs a Mac with macOS 26 or later and Apple Intelligence turned on (System Settings > Apple Intelligence & Siri). A
Debug build can show it with `-FishBrainSampleData -FishBrainSampleAI -FishBrainSampleOnDevice` (it makes Apple
Intelligence the chosen provider; it is the real model, the companies' are pretend), plus `-FishBrainShowComposer`,
`-FishBrainShowSettings` (opens Settings on the AI tab) and `-FishBrainSampleDraft` (starts a run on the topic).

- **Settings > AI** has a third card, "Apple Intelligence (on device)". Available: "✓ Available", a radio button to
  use it, "Free and private: nothing leaves your Mac...", and how many words it reads at a time. Turn Apple
  Intelligence off in System Settings and come back to FishBrain: it says "Not available on this Mac" with what to do,
  and the radio is dimmed. On a Mac older than macOS 26 it says "Needs macOS 26 or later."
- It is only used once chosen. With no keys and Apple Intelligence available, the composer still says "Set up an AI
  provider to start" until you choose it. Choose it: the Generate row reads "Apple Intelligence - on this Mac, free" with
  no cost line, whatever the cost switch says. Remove the key of a company you were using: it does not switch to this
  one by itself.
- **Text and PDFs:** add a PDF with selectable text and generate. Page chips ("p. 12") follow the PDF (a range of
  pages keeps the original numbers). Cards stream in as they finish, per part of the material. A long PDF takes a while
  (each part is its own request to the model).
- **A scan** (a PDF with no selectable text) gets a red message on its chip: the model reads words only.
- **Pictures:** on macOS 27 the model can look at a picture: add a photo of a page or a whiteboard and generate. Where it
  can't, a picture chip says "Apple Intelligence can't read pictures on this Mac."
- **Long material:** more than it reads in one go (a few thousand words per part, up to 10 parts) gets a grey note under
  the chips ("... Cards will come from the first part"), and the run uses the first part. Choosing a page range changes
  what the first part is.
- **No material, only "What matters to you":** works, with a note that a model this small gets facts wrong. Check those
  cards.
- Refine and ↻ work (from the cards, without the material). Stop stops the model. A language the model can't write in
  says so ("Apple Intelligence can't write in this language") and offers Start over.
- Nothing is sent anywhere: watch Activity Monitor's network tab, or run with the Wi-Fi off.

## Grading in the deck view (FLAS-56), to check by hand

A Debug build: `-FishBrainSampleData` is enough.

- Under the Now showing card are four buttons, Again, Hard, Good and Easy, each with a gap ("1 min", "10 min",
  "1 day", "4 days" for a new card). They are dimmed and do nothing while the front is showing; the panel is the
  same height before and after the flip. Click the card: they come alive, and Good is accent-tinted.
- Click Good: the next card appears (front showing), the buttons dim again, and the count line under the panel
  goes up by one ("1 of 20 today"). Open the notch: it shows the same card. Flip and grade there instead: the
  panel follows within a moment.
- Press 1 to 4 with the list focused or while typing in a card: nothing is graded. Tab reaches the four buttons;
  VoiceOver reads "Good, next in 1 day"; while dimmed it adds "Turn the card over first".
- The card list has a **Status** column: New, Learning · 10 min (graded Hard, or forgotten), Due now, In 4 days,
  Mastered · 3 mo (next review 21 days or more away). The card showing now keeps its highlighted row.
- Narrow the window: at about 1130 pt the Status column drops under each card's text, and at the 920 pt minimum
  Front, Back and the chip stack in a row of their own.
- At 920 × 480 the Now showing card is shorter but the buttons and count line are all in view.
- The header has **Learn** and **Review** (dimmed, "Coming soon") and one **Add ⌄** menu: Add Card, Paste Cards,
  Import CSV, Generate… (dimmed with its reason when no AI provider is set). At 920 pt the title and buttons share a row.

## Learn mode (FLAS-57), to check by hand

A Debug build: `-FishBrainSampleData` is enough.

- **Learn** in a deck's header opens a full-window screen (the sidebar goes away). Esc or **Leave Learn** returns to
  the same deck. Picking another deck, New Deck or Create with AI also ends Learn.
- On an empty deck, Learn shows "Add a card to start learning" and does not open.
- One large card with the front showing; "1 / 4" and a shuffle button at the top right; the key hints
  (Space flip, arrows move, S shuffle, Esc leave) fade out after about six seconds.
- Click the card or press Space: it turns over to the accent-tinted answer with "Answer". Turn Reduce Motion on in
  System Settings: the flip becomes a cross-fade and the fish steps instead of gliding.
- Right arrow moves on and always shows a front. Left arrow on the first card does nothing (the button dims).
  Right arrow on the last card shows **Round complete** with **Go again** (Return) and **Leave**; left arrow from
  there returns to the last card.
- **S** shuffles and starts again from the first card; moving about keeps that order. Go again keeps the same order.
- The fish sits at the left on the first card and the right once the round is complete.
- Open the notch before and after a Learn run: the card it shows, its flip and the Now showing panel are
  exactly as they were. Turned-over cards raise "n of 20 today" (the notch's open line) once each; flipping the
  same card again, or a second round, doesn't count it twice that day. No card gets a review (Status stays New).
- VoiceOver: the card reads like in the notch ("la sobremesa", then "Answer, ..."), with actions for Next card,
  Previous card, Shuffle and Leave Learn; moving announces the new card.

## Review sprint screens (FLAS-59), to check by hand

A Debug build: `-FishBrainSampleData`. Grade a few cards from the notch first so some are due, or wait a
minute after grading Again.

- **Review 10 min** in a deck's header opens the **Review sprint** sheet with that deck ticked. Rows show
  "n due" or a green "Caught up"; the line under the list reads "1 deck ticked · 3 due · 5 new" and follows
  the ticks. Chips: **This deck**, **Everything due**, **Clear**.
- 5, 10, 15, 25 min and **Custom** (a stepper from 1 to 60). Pick 15, start, finish, open the sheet again:
  15 is still chosen, and the header button reads "Review 15 min".
- **Which cards** shows each choice's count ("20 due, then 34 new", "20 cards", "140 cards"). Everything,
  shuffled greys out "Shuffle between decks". The estimate line ("About 21 cards at your usual 2.1 a minute")
  stays hidden until sprint history exists (a later story).
- **Start 10:00** is dimmed, with the reason beside it, when nothing is ticked ("Tick at least one deck.") or
  when Due only has nothing due.
- Start: the window becomes the sprint. Reviewed, a big m:ss clock, due left, a fish on a hairline, the card
  front (with its deck name when two or more decks are mixed). The four grade buttons are dimmed until you press
  **Space** (or click the card); then 1 to 4 grade, and **Space** again grades Good.
- **P** (or Pause) blurs the card and stops the clock; nothing can be graded until you resume. **Esc** (or End
  sprint) asks first; "Keep going" returns, "End sprint" shows the results.
- Let a short sprint run out: "Time's up · grade this card to finish" appears; grading the card on screen ends
  the sprint. Pausing is off at 0:00. With VoiceOver on, hear "1 minute left", "30 seconds left", "Time's up".
- Grade a card **Again**: it returns a few cards later and "due left" doesn't drop for it.
- Open the notch before and after: its card and the widget's rotation haven't jumped because of the sprint
  (only the due ordering can change what they show).
- **Results**: the big count and "cards in 10:00 · 2.3 a minute", Remembered (Good or Easy), the stacked grade
  bar with counts, today's count and streak, **By deck** (when more than one deck) and **Came up again** with
  deck names. **Review the n missed · 1 min** runs a one-minute sprint of exactly those cards; **Same mix
  again** starts the same decks and choices; **Done** (or Esc) returns to the deck.
- Turn Reduce Motion on: the fish steps (every 15 seconds) instead of gliding, and the flip is a cross-fade.

## Sprint history (FLAS-60), to check by hand

- Run three Review sprints of 5 minutes or more (or end them early after at least 3 minutes). Open the setup
  sheet: the line "About N cards at your usual X.X a minute, across 1 deck." now appears. With fewer than three
  such sprints, or only 1 and 2 minute ones (Review the missed rounds), it stays hidden.
- On the results of the fourth sprint, **Your usual pace** and **Last sprint** appear; "Last sprint" is the third,
  not the one you just finished.
- End a 10-minute sprint after about 4 minutes: next time, "Last sprint" reads "n cards in 4:00".
- A sprint with nothing graded leaves no trace.
- `runs.json` is in the same folder as `study.json`. Put garbage in it and open a sprint: it is renamed
  `runs.corrupt-<time>.json`, no estimate is shown, and the next sprint starts a new file. `decks.json` is unchanged.

## Notch and Review sprint share one clock (FLAS-61), to check by hand

A Debug build on a Mac with a notch, or with "Show on external displays" on, plus `-FishBrainSampleData`.

- With nothing running the notch is as before: Start session with a length that cycles 5, 10, 15, 25 and
  the pill's "Last: N cards".
- Start a notch session, flip a few cards, then start a Review sprint from a deck's header: before it begins
  you are asked "A notch session is running", with "12:40 left, 8 cards reviewed. Starting a sprint ends it and
  keeps its 8 cards." **Keep session** leaves everything as it was; **End it, start sprint** ends the session
  (its cards are kept in today's count) and starts the sprint.
- While the sprint runs, the notch pill shows the ring, time left and "N reviewed" (drawn notch), and the open
  notch shows "Sprint · 7:42 left · 17 reviewed" with **Go to sprint** where Start session was. Go to sprint
  brings FishBrain forward. VoiceOver reads the pill as "Review sprint, 7:42 left, 17 cards reviewed".
- The notch keeps rotating its own card every five minutes during a sprint, and its grade buttons still work.
- Pause the sprint: the time left in the notch stops too.
- Let the Mac sleep for a few minutes mid-sprint and wake it: the sprint is still there with the time
  reduced by the sleep; nothing in the notch ended it.
- End the sprint: the notch shows "n cards in m min" for eight seconds and then "Last: n cards", the same as
  after a session. Cards graded in the sprint appear once in "n of 20 today".
- Start a sprint, grade a card or two, then quit FishBrain: open it again, and the last sprint is in the
  history (and "Last: n cards" in the notch).

## Subjects in the sidebar and the subject page (FLAS-63), to check by hand

A Debug build with `-FishBrainSampleData`. Use **+ New > New Subject** a few times to make Spanish, then
Grammar inside it, then Verbs inside Grammar, and file some decks with New Deck in <subject>.

- The sidebar has **Subjects** (expandable) and **Decks** (loose decks). Create with AI stays above them.
- It never indents more than one level. Opening Spanish shows Grammar (with a › at its end) and Spanish's
  decks. Grammar doesn't expand: clicking it opens its page.
- Counts on a subject row are for everything inside it. VoiceOver reads "Grammar, subject, 52 cards, 5 due".
- Open Verbs (the third level, from Grammar's page): the sidebar marks Grammar with a lighter fill and an accent
  bar; the page has a breadcrumb "Spanish › Grammar" and each part works as a way back. Collapse Spanish: the
  mark moves to Spanish.
- Quit and reopen: the subjects that were open are still open. Up and Down move through the visible rows;
  Right opens and Left closes the selected top-level subject.
- **+ New** (bottom of the sidebar): New Deck (⌘N), New Subject (⇧⌘N), then "New Deck in <subject>" and "New
  Subject in <subject>" for where you are. In Verbs, New Subject in Verbs is off and says "Three levels is the
  most. Pick New Subject in Grammar instead." A new subject starts with its name in edit, like New Deck.
- **Add Card** is now ⌥⌘N (File menu).
- A subject's page: icon (click for colour), editable name, subtitle "1 subject and 2 decks inside · 126 cards
  in all, 14 due". **Subjects inside** tiles look stacked; **Decks** tiles have a stacked bar and "9 due · 22
  mastered · 12 new" or "Caught up · ...", with Learn and Review; the dashed tile makes a deck in the subject.
- An empty subject explains itself and has New Deck and New Subject buttons.
- A deck inside a subject has the breadcrumb above its title. Search for a card in a deck inside a collapsed
  subject: the subject opens and the deck is selected. So does a widget's link to that deck.
- Moving, dragging and deleting subjects is the next story; the sidebar's right-click offers Rename and Color.

## Moving and deleting subjects and decks (FLAS-64), to check by hand

With a library from the FLAS-63 checklist (Spanish > Grammar > Verbs, and Biology).

- Drag a loose deck onto Spanish: it is filed there, Spanish opens to show it, and the deck is still the open
  one. Drag it onto the **Decks** heading: it is loose again. A schedule (due counts) is unchanged.
- Drag Grammar onto Biology: Grammar comes with Verbs and its decks. Drag Biology onto Grammar (or Spanish onto
  Verbs): the pointer shows not allowed and the row says why ("A subject can't go inside what it holds."). A
  subject that already holds two levels, dropped on a second-level subject: "Three levels is the most."
- Drag a sub-subject onto **Subjects**: it becomes top level.
- Right-click a deck or subject > **Move to…**: only places that work are listed; none are greyed. A subject
  that fits nowhere has no Move to… at all.
- Right-click a subject > **Delete…**: "Delete “Grammar”?" with "It holds 1 subject, 2 decks and 52 cards.", the
  default **Move its contents up**, the red **Delete subject and its ...**, and Cancel. An empty subject just
  asks Delete or Cancel. Delete the open subject: its parent opens (or the first row, for a top-level one).
- **⌘Z** after each of these puts it back, in the same place, with edits made since kept (a rename, a card).
  ⌘⇧Z does it again. Delete a deck with pictures, undo, and the pictures are there.
- The subject page's **⋯** menu has Move to… and Delete….

## Subject paths in search, the notch picker and the widget (FLAS-65), to check by hand

Make two decks called "Verbs": one in Spanish > Grammar, one in French.

- Search for a word on a card in each: the result's last line reads "Spanish › Grammar › Verbs" and "French ›
  Verbs", not just "Verbs". A loose deck's result shows just its name. VoiceOver says the same path.
- Choose a result: the deck opens and Spanish (or French) opens in the sidebar to show it (or the nearest
  subject it can show, marked).
- Open `fishbrain://deck/<id>` for a deck inside a collapsed subject (from a widget tap): the same.
- Sidebar footer, the notch's deck picker: with subjects it is grouped by path ("Spanish › Grammar › Verbs",
  "French › Verbs") and loose decks come last under "Decks". With no subjects it is the flat list as before.
  A deck deleted while chosen falls back to the first deck.
- Right-click a widget > Edit Widget: the deck list shows each deck's subject path as its subtitle. A widget
  configured before subjects existed still shows its deck.
- The widget and the open notch's card header show only the deck's name.
- A name over 24 characters is shortened in the middle of that part ("Intermediate… and tenses").

## Mixing subjects and decks in a sprint (FLAS-66), to check by hand

With Spanish > Grammar > Verbs (decks in each), Biology, and a loose deck.

- Open **Review** on a deck. The sheet's list is the library as a tree, all three levels indented, each row
  with "n due" or "Caught up". A subject with no deck anywhere inside is greyed and can't be ticked.
- Tick **Verbs**: both its decks tick. **Grammar** and **Spanish** show a dash (some inside are ticked); tick
  the rest and they show a check. Untick Spanish and everything inside clears.
- The summary line ("4 decks ticked · 20 due · 34 new") and the three "Which cards" counts follow what is
  ticked, as does the estimate.
- Chips: **This deck**, the name of the subject whose page is open (only then), **Everything due**, **Clear**.
- In the sidebar, ⌘-click a few decks and subjects: they take a lighter fill, the open page doesn't change, and
  **Review 3 decks** appears above + New. Shift-click chooses the run from the last one clicked. A plain click
  clears it. The **×** beside the button clears too.
- **Review 3 decks** opens the sheet with those (and everything inside chosen subjects) ticked.
- Start a sprint, finish it, open Review again from a deck that was in it: the same mix is ticked. From a deck
  that wasn't: just that deck. Quit and reopen: nothing is remembered. Delete a deck that was in the last mix:
  it is silently left out.
- Move a deck out of a ticked subject while a sprint runs: the sprint's cards don't change.
- The running screen shows each card's deck name; the results have the By deck split.

## Learn all and Review… for a subject (FLAS-67), to check by hand

With Spanish > Grammar > Verbs (decks at each level), a second sub-subject with a deck, and an empty subject.

- Spanish's page header has **Learn all** and **Review…** before the ⋯ and New menus.
- **Learn all**: a full-window Learn on the first card of the first deck. The top bar says "Spanish · Learn all"
  with the card's deck name under it, quietly. The decks go in the sidebar's order (sub-subjects' decks first,
  then Spanish's own); the position reads "1 / N" over every card inside.
- Space, arrows, **S** work as in Learn; S mixes cards across decks. Turn cards over, leave, and look at the
  notch: today's count went up once per card; no due dates changed.
- **Review…** opens the sprint sheet with every deck inside Spanish ticked (Spanish itself shows a check, Grammar
  and Verbs too) and the Spanish chip available. Start 10:00 mixes those decks.
- A subject tile (Grammar) has **Learn** and **Review**: Learn goes through just Grammar's decks; Review opens the
  sheet with them ticked.
- An empty subject's page, and its tile, have both buttons dimmed; hovering says "There are no decks in this
  subject yet." (or "...no cards...").
- Esc, or Leave Learn, returns to the subject's page.

## Exporting to CSV (FLAS-69), to check by hand

With Spanish > Grammar > Verbs (decks in each), a loose deck, and one card with a picture.

- Right-click a deck > **Export…**: the sheet names the deck and its card count. **Anki package** is dimmed
  ("Coming soon"). Press **Export…**, choose a place, and the done screen shows the file, its size, and
  **Show in Finder** and **Share…** (AirDrop, Mail, Messages).
- Open the file in Numbers and in Excel: accents are right, a card with a line break stays in one cell, a
  card with commas or quotes is intact. Header row reads Front, Back.
- Switch **Semicolon**: the file opens in columns in an Excel set to a European language. **Tab** too.
- Turn off **First row names the columns**: the file starts with the first card.
- On a deck, turn on **Add Deck and Subject columns**: columns three and four are the deck and its full path
  ("Spanish › Grammar › Verbs").
- Subject page ⋯ > **Export…**, or right-click the subject: the sheet lists every deck inside with a tick and
  its card count; the Deck and Subject switch is on and can't be turned off. Untick one deck and the count
  and file change. Paths start at the exported subject ("Grammar › Verbs" when exporting Grammar).
- **File ▸ Export…** (⇧⌘E) on a deck, on a subject page, and with nothing open (the whole library).
- A card with a picture: the sheet says "1 picture can't go in a CSV file", and the done screen repeats it.
- An empty deck, or a subject with no cards: Export… in the menus is dimmed, with a tip saying why.
- Import the exported deck file back with **Add ▸ Import CSV** on a new deck: same cards, same text. Import
  the subject file the same way: all its cards land in one deck (decks and subjects are rebuilt in a later
  ticket).
- A file name with a slash or colon in the deck's name is saved with a dash.

## Importing a CSV with structure (FLAS-70), to check by hand

Use the file from Export (FLAS-69) of a subject, and a plain two-column list.

- **File ▸ Import…** (⇧⌘I) opens a sheet with a drop zone. **Choose File…** takes .csv, .tsv and .txt.
  Drop a .csv on the main window: the sheet opens on it. Drop a picture on the window: nothing happens.
- Choose the exported subject file: the sheet names the file, rows, columns, encoding and separator;
  Front, Back, Deck and Subject are matched; the preview shows "Spanish › Grammar › Verbs" style places.
  "Make decks and subjects from the file" is chosen and says how many subjects and decks it makes.
  **Import** > the result screen lists the decks; **Open “Spanish”** goes to it. ⌘Z removes everything,
  ⇧⌘Z puts it back.
- Import the same file again: new subjects and decks are made next to the old ones, never merged.
- Change **Front of card** to another column: the preview and counts follow. Put front and back on the same
  column: Import is disabled with a reason.
- Turn off **First row is a header** on a file with one: the header becomes a card.
- A file with a blank Back on a row: the row is red in the preview, "1 row skipped" in the footer, and on
  the result screen **Show** lists "Row 5: empty back".
- Right-click a subject > **Import…**: new subjects and decks land inside it. In a subject two levels deep,
  a file with a three-level path puts the extra names in the deck's name ("Two - Verbs").
- **Add ▸ Import CSV** on a deck: the file chooser opens at once, "Add everything to one deck" is chosen
  with that deck. Turn on **Skip cards that are already in the deck** and re-import: the count says how
  many were already there.
- A semicolon-separated file (save from Excel set to a European language) reads in columns. A file saved as
  Windows Latin-1 says so in the details.
- A one-column file: Import is disabled with "Choose a different column for the front and for the back."
  A .pdf renamed .csv, or an empty file, shows the reason in the sheet.

## Importing an Anki package (FLAS-71), to check by hand

Use a real package from AnkiWeb or your own Anki: one with nested decks, pictures, a Cloze note and a
"Basic (and reversed card)" note. Export from Anki with File > Export > Anki Deck Package, and tick
"Support older Anki versions".

- File ▸ Import…, Choose File…, pick the .apkg (or drop it on the window). The sheet names the package,
  its size, decks, notes and pictures.
- Decks in this package: nested decks are indented, all ticked. Untick one: the footer count drops.
- "How cards are brought in" lists each note type with its count and what happens to it. Image Occlusion
  (if present) is in amber as unsupported.
- **File them under**: Top level, or a subject. Choose one, import: the new subjects are inside it.
- **Import**: the result lists the decks made. Open them: front and back are plain text, line breaks
  kept, no HTML. A Cloze note shows […] on the front and the full sentence on the back, one card per blank
  number. A reversed note is one card.
- A card whose field has a picture shows it above the text; a card with only a picture has an empty text.
- **Show** on the report: skipped notes with their reason, extra pictures, missing pictures. Sounds are
  counted at the top.
- ⌘Z removes everything and ⇧⌘Z puts it back with the pictures. Quit and reopen: pictures are still there.
- Export from a current Anki **without** "Support older Anki versions" and import it: the sheet says the
  package is in a newer format and how to export it.
- A .zip that isn't a package, and a .pdf renamed .apkg, show a plain message and import nothing.
- Cards are all new: no due dates came along.

## Exporting an Anki package (FLAS-72), to check by hand

With Spanish > Grammar > Verbs (decks in each), a loose deck, and a card with a picture and a description.

- Right-click a subject > **Export…**, choose **Anki package**: the CSV options give way to "What is
  written", the footer says "Saves as Spanish.apkg · about … MB". Untick a deck: the card count and size
  follow. **Export…** > save > the done screen shows the .apkg.
- Open the file in **Anki** (double-click, or File > Import). It must import with **no warning**. Check:
  decks nested "Spanish > Grammar > Verbs", every note a Basic with Front and Back, line breaks kept,
  `<` and `&` shown as typed, the picture on the card with its description as the image's alt text.
- All cards are new, in the same order as in FishBrain.
- Export the same subject again and import into Anki again: Anki says the notes are unchanged or updated,
  and does **not** make a second copy. Change a card's text in FishBrain, export, import: that note updates.
- Export a single deck: it comes in as one deck named after it (no subject path).
- Import the file back into FishBrain (File ▸ Import…): same subjects, decks, text and pictures.
- Export from an empty deck or a subject with no cards: Export… is dimmed with the reason.

## Sharing: where it lives, and opening files (FLAS-73), to check by hand

Do this on a Mac that has Numbers (or Excel) and, ideally, Anki installed.

- **Menus.** Right-click a deck: **Export…**. Right-click a subject: **Import…** and **Export…**. A deck
  page has a ⋯ next to Add with **Export…**; a subject page's ⋯ has **Move to…**, **Import…**, **Export…**.
  The sidebar's **+ New** ends with **Import…** (below a divider), also in a subject (with the "in" items).
  A deck page's **Add** menu has **Import…** (it was "Import CSV"); an empty deck's button says the same.
- **File menu.** **Import…** (⇧⌘I) and **Export…** (⇧⌘E). With a subject page open, Export… is that
  subject; with a deck, that deck; with nothing, the whole library. With nothing to export (a new empty
  library, or an empty deck open) **Export…** is dimmed; add a card and it comes on without reopening the menu.
- **Double-click.** In Finder, double-click a .csv: it opens in Numbers/Excel as before (FishBrain doesn't
  take it over). Right-click > Open With > **FishBrain**: FishBrain comes to the front on the Import
  sheet with that file already read. Same for a .tsv and a .apkg. Do it with FishBrain closed: it launches
  and shows the sheet.
- **AirDrop.** Export a deck as .apkg, AirDrop it to another Mac. Click Open in the AirDrop notification,
  or open it from Downloads with FishBrain: the same Import sheet.
- **Drop.** Drag a .csv and an .apkg onto the open window: both open the sheet. Drag a .png onto the window
  (not onto a card): nothing happens. Drag a .png onto a card side: it becomes the picture, as before.
- **Share.** On the done screen, **Share…** lists AirDrop, Mail and Messages; sending to Mail attaches
  the file.
- **Anki both ways.** Export a subject with a picture as .apkg and open it in Anki: no warning, nested
  decks, the picture. In Anki export one of its decks (Support older Anki versions ticked) and import it in
  FishBrain: cards, structure and pictures arrive; the result lists what was skipped.
- **Nothing is uploaded.** Turn Wi-Fi off and repeat an export and an import: both work.

## Light themes (FLAS-79 to FLAS-83), to check by hand

Checked in a Debug build with `-FishBrainSampleData -FishBrainSkipWelcome -FishBrainAppearance <light|dark|system>
-FishBrainAccent <orange|indigo|blue|purple|teal>` (the last two are Debug-only, for screenshots):

- [x] Main window in light with Orange and with Teal, and in dark with Orange: sidebar tint, white text on
  the selected row and on Review, the sun/moon button between Review and Add, Now showing, grade buttons,
  status chips, the switch and the countdown bar.
- [ ] Subject page, Learn, Review sprint setup and results, Create with AI, import and export sheets,
  Settings (Appearance tiles, five accent swatches), welcome sheet: in light with Orange and one other
  accent, and in dark with Orange.
- [ ] The toolbar button: menu opens with a check on the current choice, the button turns accent while it
  is open, Esc and a click outside close it, choosing applies at once. VoiceOver reads "Appearance" and
  "Light" / "Dark" / "Match system, now light".
- [ ] Make the window narrow: the button moves into the ⋯ menu as Appearance ▸ before the toolbar wraps.
- [ ] View ▸ Appearance shows a check on the current choice and stays in step with the button and Settings.
- [ ] Match system: switch the Mac between light and dark (System Settings > Appearance) with FishBrain
  open; the window and the button's icon follow.
- [ ] Window glass over a dark photo, a bright one and a busy one: text stays readable in light.
- [ ] Reduce Transparency and Increase Contrast (System Settings > Accessibility > Display): solid
  surfaces and stronger hairlines in light and dark.
- [ ] Widget in all three sizes, front, flipped and empty, in light and dark; in the tinted/accented
  widget mode and dimmed in the background on the desktop.
- [ ] Notch: black with light text with the app in light. A Mac without a notch (drawn notch) with a
  light and with a dark menu bar.
- [ ] Update from 1.0 with Indigo saved: opens in light with Orange; with Teal saved: light with Teal.
  Switch to Dark and Indigo, quit and reopen: they stay.

## Editing in the Now showing preview (FLAS-84), to check by hand

A Debug build with `-FishBrainSampleData -FishBrainSkipWelcome`. Covered by tests: the edit model (save, trim,
empty front, cancel, every discard), undo, the row's draft, the panel's height and the field's VoiceOver
label. The rest needs a person.

- **Mouse.** Hover the card: a pencil replaces 3/4 (tooltip "Double-click to edit"), the text gets a light
  highlight, and the pointer is an I-beam over the text only. Click once: the card flips after a short pause.
  Double-click the text: it becomes a field with the caret at the end, the card has an accent outline, the
  label reads "Editing card", the bar reads "Timer paused while editing", Cancel and Save replace the grade
  buttons and nothing moves. Double-click away from the text: one flip, no editing.
- **Trackpad**, with tap to click on and off: the same as the mouse, including a double tap on the text.
- **Typing.** Return saves; Shift+Return adds a line; Esc cancels. Clear the front and press Return: the field
  gets a red outline and stays open. Clear the back and save: allowed. "  hola  " saves as "hola".
- **Held card.** Start editing with under 10 s left on the countdown and wait: the preview keeps the card while
  the notch and widget move on. Save: the preview shows the live card and its countdown.
- **Table.** While typing, the card's row shows the draft in the accent color and scrolls into view. Cancel: the
  row goes back. Save, then ⌘Z: the old text is back; ⇧⌘Z: the edit again. Click into any row while editing:
  the preview's draft is gone and the card has its saved text.
- **Leaving.** Mid-edit, pick another deck, a subject, Learn, Review, close the window, quit: each time the
  card keeps its saved text, with no prompt. Delete the card in the table mid-edit: editing ends.
- **Keyboard only** (System Settings ▸ Keyboard ▸ Keyboard navigation on): Tab reaches the card; Space flips;
  Return edits the side showing; Return saves and Esc cancels. Right-click the card: Flip and Edit Front (or
  Edit Back when flipped).
- **VoiceOver.** The card's hint is "Flips the card. Actions available."; VO-Command-Space lists Edit card.
  In the field VoiceOver reads "Front, text field" (or "Back"), and says "Saved" or "Cancelled" afterwards.
