# Contributing

MeetingCopilot is a native macOS preview. Start with the [verification ledger](docs/verification.md) to distinguish an implementation defect from an account, permission or untested compatibility boundary.

## Build and test

Use Apple Silicon and a stable full Xcode installation. The recorded toolchain is Xcode 26.6 / Swift 6.3.3; the app targets macOS 15.0 or later.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --arch arm64 --product MeetingCopilot
./script/test.sh
```

The ordinary suite does not download models, request capture permission, or make live paid API calls. Native Keychain and hotkey registration checks are opt-in:

```sh
MEETINGCOPILOT_KEYCHAIN_TEST=1 MEETINGCOPILOT_HOTKEY_TEST=1 ./script/test.sh
```

Keychain checks use unique synthetic test items. Hotkey registration is not proof of physical key delivery across applications. Model/corpus-dependent benchmarks and the four-hour soak have separate setup and workload limits in [docs/benchmarks.md](docs/benchmarks.md).

`./script/build_and_run.sh` stages and launches the app. It stops running processes named `MeetingCopilot`, including in `--build-only` mode; finish any active session first. Keep benchmark measurements tied to an exact source snapshot and artifact, and record concurrent host activity.

## Focus a change

- Explain the user-visible problem, the final behavior, and the validation you actually ran.
- Keep application coordination, domain state and native adapters within their existing ownership boundaries. See [architecture](docs/architecture.md).
- Preserve regression assertions and earlier failed evidence. New behavior deserves a focused test; a fixture does not establish live account or capture support.
- Keep subscription OAuth primary and the API-key path optional. Use only a client registered for this app; never borrow another integration's identity or credentials.
- Preserve third-party notices and pinned model provenance. Do not commit model weights, private meeting material, downloaded corpus audio, credentials, or local build/cache directories.

For a bug report, include the macOS version, chip, app/source revision, exact steps and expected/observed behavior. Diagnostic metadata such as source state, error code and queue counters is useful. Keep tokens, meeting text, screenshots containing private material, and raw personal audio out of public issues.

The [history note](docs/history.md) explains the logical first-public-import commits and the preserved original Git bundle.

## License

Contributions to the original project code are made under Apache-2.0. Preserve third-party notices and keep model/data licenses separate.
