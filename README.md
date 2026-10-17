# FishBrain

![CI](https://github.com/phdz-ng/FishBrain/actions/workflows/ci.yml/badge.svg)

macOS flashcard app with an interactive WidgetKit widget. Requires macOS 14.0+.

![FishBrain main window with the Everyday Spanish sample deck](docs/images/main-window.png)

## Install

Download the latest `FishBrain-<version>-unsigned.dmg` from the
[Releases page](https://github.com/phdz-ng/FishBrain/releases), open it and drag FishBrain to
Applications. Or build it yourself, as below.

The app is not signed with an Apple Developer ID, so macOS blocks it the first time. Allow it once in
**System Settings > Privacy & Security > Open Anyway**; the steps for each macOS version are in
[docs/opening-an-unsigned-app.md](docs/opening-an-unsigned-app.md). The desktop widget depends on
macOS loading an unsigned extension, which it may not do on every Mac (see "Signing and App Group"
below); the main window and the notch work either way.

## Build

1. Install Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
2. Generate the project (it is not checked in; `project.yml` is the source of truth):
   ```sh
   xcodegen generate
   open FishBrain.xcodeproj
   ```
3. Run the `FishBrain` scheme. In Debug builds, the launch argument `-FishBrainSampleData` (Product > Scheme > Edit Scheme > Run > Arguments) shows sample decks without touching your real library.

## Test

```sh
xcodebuild -project FishBrain.xcodeproj -scheme FishBrain -destination 'platform=macOS' test
```

CI (`.github/workflows/ci.yml`) builds the app and widget and runs the tests on every pull request
and every push to `main`.

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

## AI settings

Settings > AI holds the accounts that Create with AI will use. `AIAccountStore` ties together a key per
provider, whether it works, the models it can use and the choices made.

- **Keys** are generic passwords in the macOS Keychain (service `com.fishbrain.ai.anthropic` and
  `com.fishbrain.ai.openai`, this Mac only). They are read when a request is made and are never in
  `settings.json`, `decks.json`, a log, a published value or an error. The field shows `sk-ant-•••3f9a`.
- **Checking a key** is asking for the model list: Anthropic `GET /v1/models` (header `x-api-key`, with
  `anthropic-version`; pages followed with `after_id`), OpenAI `GET /v1/models` (`Authorization: Bearer`).
  401 and 403 read "This key was rejected"; no connection reads "No network connection". The lists are
  cached in `ai-models.json` (model names only), so the picker works offline, and asked for again when
  Settings opens if a list is over a day old.
- **Which models are listed.** Anthropic's list says what each model can do: only those with structured
  output are listed, and ones without picture input are marked "text and PDF only". OpenAI's list is only
  ids and includes embeddings, audio and so on, so by default only `gpt-` models without audio, image or
  search in the name are shown (newest first); Show all models lists everything.
- **Defaults:** `claude-opus-5-5` and `gpt-6-astra` when the key can use them. A saved model that later
  disappears is replaced by the default and the person is told once.
- **Prices** aren't in either provider's list, so they come from a table in `AIPricing`. **Whoever changes a
  price must update `AIPricing.lastUpdated` in the same commit.** Every price or cost shown reads "(estimate
  · prices updated 8 Oct 2026)", with the date in the person's own format.
- **Network:** only the app has `com.apple.security.network.client`; the widget never goes online.

## Making cards with AI: the core

Everything the two providers share (`FishBrain/AI`), with nothing online in it:

- **`GenerationRequest`** is the sources (PDFs, pictures, pasted or loaded text), what matters to the
  person, how many cards, the style (question and answer, term and definition, fill in the blank), the
  language, the fronts the deck already has, and the model. **`CardGenerator`** is the protocol a
  provider implements: `generate(_:)` returns an `AsyncThrowingStream<GenerationEvent, Error>` of the
  deck's name, each card as it is finished, and the tokens used. Failures are one `GenerationError`.
- **`CardSchema.schema`** is the JSON the model must return (`deckName`, then `cards` of `front`, `back`,
  `sourcePage`). It is an `OrderedJSON` because property order is the order the model writes them in and
  `deckName` must come first; **a provider must send `CardSchema.schema.text` (or `.data`), not a
  dictionary, which would shuffle the keys.** It stays inside both providers' rules (every object closed,
  every property required, no length, range or size limits); `CardSchema.violations()` checks that. The
  number of cards can't be set in a schema, so it is asked for in the prompt and checked afterwards
  (`CountCheck`: fewer gives "Got 17 of 20" and "Add 3 more", more keeps the first N).
- **`GenerationPrompt`** (versioned) holds the instructions and builds the parts to send, in order:
  PDFs and pictures first, then text, then what to make. It tells the model the sources are material to
  study, not instructions, so text inside a PDF can't take over.
- **`StreamingDeckParser`** reads the streamed JSON as it arrives, however the chunks fall (inside an
  escape, a `\u00e9`, a surrogate pair or a number), and reports the name and each card the moment it is
  finished. **`DeckStreamReader`** wraps it and, when the answer ends, reads the whole text once with a
  real JSON decoder, which has the last word; if that fails the cards already shown stay and the result is
  `.badResponse` (a provider that knows the answer ran out of room says `.truncated` instead).
- **`GenerationInputs`** turns files into something that can be sent: a PDF (password protected ones are
  turned down; a page range makes a smaller PDF whose card page numbers still follow the original),
  pictures (scaled to 2000 px on the long edge, JPEG or PNG), text files, pasted text. `request.sizeProblem`
  refuses more than 30 MB (the providers' limits are 32 and 50) or more than 600 pages of PDF.

## Making cards with AI: Anthropic

`AnthropicCardGenerator` (`FishBrain/AI`) is the `CardGenerator` for Claude, over raw HTTP (there is no
official Swift SDK). Make one per run with the key and the chosen `AIModel` from the model list; it streams
`POST /v1/messages` and reports the deck's name, each card as it is finished, and the tokens used.

- **The body follows the model** (`AnthropicCapabilities`, from what the model list says): `max_tokens` is
  the smaller of 64000 and the model's own; `output_config.effort` is sent only when the model supports it
  (`medium`, `low` for Haiku); `thinking`, `temperature`, `top_p`, `top_k`, `citations` and an assistant
  prefill are never sent (current models answer 400). Pictures for a model that can't read them fail with
  `.imagesNotSupported` before anything is sent, and the composer should say so first. A PDF over 100 pages
  for a model with a window under 1M tokens is `.tooLarge`. The body is `OrderedJSON`, so the schema
  keeps `deckName` first.
- **Fallbacks:** `fallbacks: "default"` and the `anthropic-beta: server-side-fallback-2026-07-01` header go
  only to the models in `AnthropicCapabilities.fallbackModelIDs` (the one place to edit that list). A 400
  that mentions `fallbacks` is asked again once without them.
- **Reading the stream:** `AnthropicStreamReader` reads `data:` lines only and only `text` blocks (thinking
  and `fallback` blocks are skipped), feeds `DeckStreamReader`, and takes usage from `message_start` and
  `message_delta`. When the model did answer, `.finished(usage)` comes before an error that follows it
  (`.truncated` for `max_tokens`, `.refused`, `.badResponse`), so the tokens used, which are billed all the
  same, are not lost. A stream that ends with no stop reason is `.network`, with no `.finished`. Cards
  already sent are never taken back.
- **Errors:** 401 `invalidKey`, 403 `modelForbidden`, 404 `modelUnavailable` (the composer should refresh the
  model list), 413 or a prompt "too long" `tooLarge`, 429 `rateLimited` with `retry-after`, 500/503/529
  `overloaded` after one more try, no connection `network`. An `error` event mid-stream maps the same way.
- **Cost:** `estimateCost(for:)` calls `/v1/messages/count_tokens` for the input and counts the output as about
  60 tokens a card (shown as a range, 0.75x to 1.5x). It returns nil, without calling, when the model has no
  price. Thinking tokens are billed as output and are not in the estimate.
- Tests use stubbed transports (`FakeStreamingAPI`, and `URLProtocol` for the real transport); CI never goes
  online.

## Making cards with AI: OpenAI

`OpenAICardGenerator` (`FishBrain/AI`) is the `CardGenerator` for OpenAI, over raw HTTP, using the
**Responses API** (`POST /v1/responses`), not Chat Completions (which only takes PDFs and has no file URLs).
Make one per run with the key and the chosen `AIModel`.

- **The body** (`OpenAIRequestBuilder`): `stream: true`, `store: false` (so OpenAI doesn't keep the response;
  it defaults to true), `max_output_tokens: 32000`, the system prompt as `instructions`, and one user message
  of `input_file` (PDF as a base64 data URL), `input_image` (`detail: auto`) and `input_text` blocks, in that
  order. The shared schema goes in `text.format` as `json_schema`, `strict: true`, name `flashcard_deck`.
  Anything over `request.sizeProblem` is `.tooLarge` before it is sent.
- **Models that can't do it:** OpenAI's model list has no capability data, so a model that can't take files,
  pictures or structured output only shows itself with a 400 about the model or a parameter. That is
  `.modelCantMakeCards` ("This model can't make cards from these files. Pick another model in Settings →
  AI") and the model is recorded in `UnsupportedModels.shared` for the session; the composer shows the
  Settings button and can grey the model out. A 400 about the input being too long is `.tooLarge`, and any
  other 400 is `.badResponse` and doesn't count against the model.
- **Reading the stream** (`OpenAIStreamReader`): `response.output_text.delta` text goes to `DeckStreamReader`;
  `response.refusal.delta` (or `refusal` content in the finished response) is `.refused`;
  `response.incomplete` with `max_output_tokens` is `.truncated` and with `content_filter` is `.refused`;
  usage comes from `response.completed` / `response.incomplete`. As with Anthropic, `.finished(usage)` comes
  before such an error. `response.failed` and `error` events stop the run with the error their code names.
- **Errors:** 401 `invalidKey`; 403 and 404 `modelForbidden` ("This key can't use this model"; the composer
  should refresh the model list: `GenerationError.needsModelListRefresh`); 413 `tooLarge`; 429
  `rateLimited` with `retry-after`, except `insufficient_quota` which is `outOfCredit`; any 5xx `overloaded`
  after one more try; no connection `network`.
- **Cost:** no token-count call exists, so `estimateCost(for:)` guesses the input from the size of what is sent
  (800 to 2500 tokens a page of PDF, 500 to 2500 a picture, 3 to 5 characters a token of text) and uses the
  same output estimate as Anthropic (about 60 tokens a card). It is a wide range, worded "about", and nil
  when the model's price isn't known. Reasoning tokens are billed as output and aren't in the estimate.
- Both providers share `StreamingTransport` (and its `URLProtocol`-tested real implementation), `CostEstimate`
  and `GenerationError`. Tests use `FakeStreamingAPI`; CI never goes online.

## Create with AI: the composer

`ComposerModel` (`FishBrain/AI`) is the state of the Create with AI screen and lives in `AppEnvironment`, so the
form is as it was left after a visit to a deck. `ComposerView` is the one-screen form; `MainWindowView` shows it
when the sidebar's **Create with AI** row (or File > Create with AI, Shift-Command-A) is chosen.

- **Sources:** `IncomingSource` is a file, a picture's bytes or text, from a drop, a Paste command, the Paste button
  or the file panel. `ComposerSourceReader` reads each into a chip (`ComposerItem`) off the main actor using
  `GenerationInputs`; what can't be read is a dismissible notice, not a chip. A PDF keeps its whole self so the
  pages can be narrowed later (`setPages`), and the card page numbers still follow the original.
- **Problems** are said on the chip (`ComposerModel.problems`): a PDF over 600 pages (or 100 on a model with a
  small window), PDFs too long together, too much to send overall, and pictures for a model that can't read
  them. A chip with a problem blocks Generate.
- **Ready or not** is `readiness`: no provider (the row becomes "Set up an AI provider to start"), nothing to
  make cards from (a source or text in the focus field), a problem on a chip, or a model that already answered
  that it can't make cards from files (`UnsupportedModels`).
- **Hand-off:** `plan(decks:)` gives a `GenerationPlan` (the `GenerationRequest`, where the cards go, the provider,
  and a generator holding the key). Generate calls `startRun(decks:)`, which keeps the form aside as a
  `ComposerSnapshot`, clears it, and makes a `GenerationDraft` (below).
- **Cost:** `refreshCost` runs a moment after the last change (the view debounces it). Anthropic is asked to count
  the tokens, which sends the material to Anthropic before Generate is pressed (Settings says so, and the switch
  turns it off); OpenAI's is worked out locally. It shows nothing when the switch is off, the price isn't known, or
  it can't be worked out.
- With no sources the prompt asks for cards about the topic in the focus field (`GenerationPrompt.version` 2).
- Debug builds: `-FishBrainSampleAI`, `-FishBrainShowComposer` and `-FishBrainSampleSources` (with
  `-FishBrainSampleData`) show the screen ready to go without a key; see `docs/QA.md`.

## Create with AI: generating and review

`GenerationDraft` (`FishBrain/AI`) is the cards being made, from the first arriving to being saved or thrown away.
`ComposerModel.draft` holds it (so it outlives the screen: leaving keeps it as the sidebar's "9/20" or "Draft");
`DraftView` shows it instead of the form while there is one.

- **State:** `generating` while the first run (or "add more") streams, then `review`. Cards come in one by one from
  the generator's events (the name first, kept as a suggestion until the person writes their own), capped at what was
  asked for (extra cards are left out). `stop()` keeps what is finished. Only one operation runs at a time
  (`activeOperation`: generate, add more, refine, rewrite).
- **Editing:** every card has a tick (all on), editable front and back, its source page and ↻. A change by hand sets
  `isEditedByPerson`. Saving takes exactly the ticked cards in order (`saveAsNewDeck` through `DeckStore.add`, or
  `save(to:)` appending to a deck) and ends the draft; the screen then selects that deck.
- **Refine all cards** sends the current cards as JSON (cards edited by hand flagged `editedByPerson`) with the
  instruction and, again, the original material, through `GenerationRequest.task = .refine(...)`; the prompt says to
  keep every other card word for word and edited cards unless asked. The whole reply replaces the list through
  `DraftMerge`: the same card keeps its id and tick, one with the same front but a new back is "changed" (briefly
  highlighted), a new front is "added". A failed or empty reply changes nothing. **↻** uses `.replace(...)`: one new
  card for the same page, told the deck's other fronts, put in the same place.
- **Failures** are one `DraftProblem` with `DraftFix`es: Open Settings, Try again, Add N more, Start over
  (`fixes(for:operation:)` has the table). Try again after a first run that gave cards asks only for the rest.
- **Cost:** tokens from every run add up (`GenerationEvent.finished`, which arrives before a cut-off or refused
  answer's error, so billed tokens count); `costText` words it "This run cost about $0.23 (estimate · prices updated
  ...)", "These runs cost" after more than one, nothing when the price isn't known.
- **Quitting** with cards that aren't in a deck (or a run in progress) asks first (`applicationShouldTerminate`);
  closing the window doesn't, the draft stays.
- **From inside a deck** (FLAS-51): the deck toolbar's **Generate…** calls `ComposerModel.prepareForDeck(_:)`, which sets
  "Put cards in" to that deck. `deckGenerateAvailability` says when it can't (no provider, or a draft already
  waiting), and the button is dimmed with that as its tooltip. `plan(decks:)` then gives the plan a `TargetDeck`: the draft
  keeps that deck's name and color (no suggestion, rename or recolor), the request carries its fronts (the prompt
  sends the last 300, each cut short), and the primary button is **Add to "Name"** (`saveToTargetDeck`). If the deck
  is gone by then, it can still be saved as a new deck.
- Debug builds: `-FishBrainSampleAI` also swaps in `SampleGenerator` (a pretend provider), and `-FishBrainSampleDraft`
  (or `-FishBrainSampleDraftInDeck`, for the first deck) starts a run at launch; see `docs/QA.md`.

## Create with AI: Apple Intelligence (on device)

`AppleIntelligenceGenerator` (`FishBrain/AI/OnDevice`) is the third `CardGenerator`: the model that comes with the Mac, through the
Foundation Models framework. No key, no network, no price (so no cost line). It is `AIProvider.appleIntelligence`, the one provider
that isn't a company's service (`AIProvider.cloud` is the two that are), and it is only used when chosen in Settings > AI.

- **Availability:** `OnDeviceStatus` (from `SystemOnDeviceModel`, or a fixed one in tests) says whether it can be used, why not
  (macOS older than 26, a Mac that can't run Apple Intelligence, it switched off, still downloading), its context size and whether it
  can look at pictures (macOS 27). `AIAccountStore.onDevice` holds it and `refreshOnDevice()` asks again (when Settings opens, and when
  the app comes forward). The app still runs from macOS 14: the framework is weak-linked (`project.yml`), every use is behind
  `#available`, and the macOS 27 calls are behind `#if compiler(>=6.4)` so an older SDK still builds.
- **The model's context is small** (8,192 tokens on macOS 27; 4,096 on 26.0 to 26.3), question and answer together. So the material is
  read as text (PDFKit, page by page; a scan has none and is turned down) and cut into parts (`OnDeviceChunker`): a part holds what
  fits next to 12 cards (about 17,000 characters at 8,192 tokens), the cards are shared out among the parts by size
  (`OnDevicePlanner`), and each part is its own request, one after another, each told the fronts the others wrote. Up to 10 parts
  per run; more is cut off and the composer says so (`ComposerModel.onDeviceNote`). A part the model says is too long is cut in half
  and tried again (up to 3 times). Pictures are a part of their own, when the model can look at them.
- **Guided generation**, not a JSON schema: `FoundationModelsEngine` asks for a `@Generable` deck (name first, then cards) and
  streams it; `OnDeviceStreamTracker` turns the partly written deck into events (the name once cards begin, a card once the next
  one starts or the answer ends), so the draft fills in card by card as for the other providers. The engine is behind
  `OnDeviceEngine` so the logic is tested with a pretend model; `OnDeviceLiveTests` use the real one when
  `FISHBRAIN_LIVE_ON_DEVICE=1` (skipped otherwise, never in CI).
- **A small model's mistakes are put right in code** (`OnDeviceCleaner`): "(sourcePage: 1)" written into a card is removed, and a
  page number stays only if the material had that page.
- **Errors:** the system's (`OnDeviceFailure`) become the usual `GenerationError`s, plus `languageNotSupported`, `onDeviceUnavailable`
  and `noReadableText`. A part stopped by the safety checks is skipped (all stopped: refused).
- **Refine and ↻** work from the cards alone, without the material, since the context is too small to send both.
- Quality: with no material it writes from what it knows and gets facts wrong (the composer says so); with notes or a PDF the cards
  follow them, though a small model is plainer than Claude or GPT.

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

See [docs/RELEASING.md](docs/RELEASING.md): `TEAM_ID=… Scripts/release.sh` builds, signs, notarizes and staples the DMG; `Scripts/release.sh --unsigned` tests the packaging without an Apple account. Release notes are in [CHANGELOG.md](CHANGELOG.md).

## Targets

| Target | Purpose |
| --- | --- |
| `FishBrain` | macOS app, sandboxed, read-write access to user-selected files (import and export) |
| `FishBrainWidget` | WidgetKit extension, sandboxed, embedded in the app |

## Contributing

Bug reports and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Report security
problems privately, as described in [SECURITY.md](SECURITY.md).

## License

FishBrain is licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE).

FishBrain is an independent project. It is not affiliated with or endorsed by Anki, Anthropic or OpenAI.
Anki is a trademark of its respective owner. Anthropic, Claude and OpenAI are trademarks of their
respective owners and are named here only to describe the services the app can connect to.
