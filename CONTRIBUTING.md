# Contributing to FishBrain

Thanks for helping. Bug reports, ideas and pull requests are welcome.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on the approach.
- Security problems go through [SECURITY.md](SECURITY.md), not a public issue.

## Build and test

You need macOS 14+, Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate          # project.yml is the source of truth; FishBrain.xcodeproj is generated
xcodebuild -project FishBrain.xcodeproj -scheme FishBrain -destination 'platform=macOS' test
```

Launch the app with `-FishBrainSampleData` to see sample decks without touching your own library
(add `-FishBrainSkipWelcome` to skip the welcome sheet).
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) covers storage, the widget and signing in more detail.

## Pull requests

- One change per pull request, branched from `main`.
- Add or update tests with the change. CI builds the app and widget and runs the whole suite.
- Update [CHANGELOG.md](CHANGELOG.md) for anything a user would notice, under an `## Unreleased` heading at the top.
- Keep personal values (team ID, signing identity, keys) out of the repository; use
  `Config/Local.xcconfig`, which is gitignored.

## License

By contributing, you agree that your contribution is licensed under the
[Apache License 2.0](LICENSE), the same as the rest of the project.
