# Making cards with AI

How FishBrain's AI features work: the settings, the Anthropic and OpenAI providers, the Create with AI screens and the on-device Apple Intelligence option. Back to the [README](../README.md).

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
