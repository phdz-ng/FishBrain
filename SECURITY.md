# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue.

Use GitHub's **Report a vulnerability** button on the repository's **Security** tab
(private vulnerability reporting). Include what you found, the steps to reproduce it and the macOS and
FishBrain versions you tested.

You can expect an acknowledgement within a week. Fixes ship in the next release and are credited in
[CHANGELOG.md](CHANGELOG.md) unless you prefer otherwise.

## Supported versions

Only the latest release receives security fixes.

## What FishBrain handles

- **API keys.** The Anthropic and OpenAI keys you enter in Settings > AI are stored in the macOS
  Keychain, sent only to the provider you chose, and never written to the library, logs or the repository.
- **Your library.** Decks and cards are plain JSON files on your Mac. FishBrain has no account or
  server of its own.
- **Copy to card.** It is off by default, and it ignores anything a password manager marks as secret.

## Please never commit secrets

If you contribute, keep API keys, certificates and provisioning profiles out of commits.
`Config/Local.xcconfig` is gitignored for your personal signing settings.
