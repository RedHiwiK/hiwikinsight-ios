# Contributing

Thanks for your interest in HiwiKInsightKit! Issues and pull requests are welcome.

## Development

```sh
swift build
swift test
# iOS compile check
xcodebuild build -scheme HiwiKInsightKit -destination 'generic/platform=iOS Simulator'
```

## Guidelines

- Keep the SDK dependency-free and small. Open an issue before adding a large feature.
- **Protocol compatibility comes first.** Any change to the request format, endpoint, headers,
  built-in events or response handling must be reflected in [PROTOCOL.md](PROTOCOL.md) and agreed
  with the [server](https://github.com/RedHiwiK/HiwiKInsight). Breaking changes require bumping `schema`.
- Do not rename persisted storage keys or file paths; existing installs depend on them.
- Never collect personal data, IP addresses or device identifiers.
- Add or update tests for behavior changes, and update [CHANGELOG.md](CHANGELOG.md).
- Use English for code, comments and commit messages
  ([Conventional Commits](https://www.conventionalcommits.org/) style, e.g. `fix: ...`).
