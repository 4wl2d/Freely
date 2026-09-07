# Continuous integration

[macOS CI](https://github.com/4wl2d/MeetingCopilot/actions/workflows/ci.yml) checks Debug and Release on the standard ARM64 `macos-26` runner with Xcode 26.6. The runner and toolchain were selected from GitHub’s [runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) and [installed software manifest](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md), checked 2026-09-07.

The workflow tests CopilotCore and native integrations, then packages an ad-hoc preview in the Release job. It uses pinned action commit IDs and read-only repository permissions. Live Keychain, global hotkey, focus, model-soak and paid API checks are not enabled on hosted CI. Their separately measured scope is recorded in the verification ledger. A green CI run does not establish capture permissions, subscription access, model accuracy or notarization.

The release ZIP attached to the preview release is the previously inspected local artifact. CI artifacts are separate builds and carry their own checksum.

Native tests run with explicit `--no-parallel`: AppKit and native protocol fixtures share process-wide infrastructure. Concurrency created inside an individual test remains exercised. `--jobs` limits compilation only. See [Apple’s parallelization documentation](https://developer.apple.com/documentation/Testing/Parallelization). Native execution has a 120-second diagnostic deadline after compilation; a stall preserves process samples and fails, rather than silently dropping tests.

The separate native-test build explicitly enables testability, including Release, so `@testable` imports can access internal declarations. The packaging step performs its normal Release build without that test-only compiler flag.
