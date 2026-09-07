# Packaging evidence — 7 September 2026

Historical logs are preserved in the [release evidence archive](evidence-archive.md); original snapshot IDs are explained in [history](history.md).

The exact source snapshot below produced Debug and Release builds, a structurally valid ARM64 `.app`, and a ZIP whose extracted files and executable modes match the staged app. All build/package commands exited 0. This is an **ad hoc signed local artifact**, with hardened runtime enabled. Gatekeeper assessment returned **3, rejected**. Developer ID signing, notarization, a relocated app launch, and operation on macOS 15 remain **NOT TESTED** by this packaging task.

No app was launched, no audio/screen capture was started, and no xAI request was made. Production source and tests were not edited. App launch, service behavior, and soak evidence belong to the separate [verification record](verification.md).

Compact inspected facts and the exact hash manifests are also versioned alongside the benchmarks: [inspection](../Benchmarks/results/packaging-inspection.json), [source](../Benchmarks/results/packaging-source.sha256), [build inputs](../Benchmarks/results/packaging-build-inputs.sha256), and [packaged files](../Benchmarks/results/packaging-app-files.sha256). Full raw build output remains local. These preserve the original snapshot; later documentation and test-fixture corrections are identified separately.

## Exact source and environment

- Original workspace: `<original-workspace>`.
- Isolated snapshot: `<original-workspace>/.cache/release-validation/20260907-packaging-01/source`.
- Raw evidence and per-command JSON: `<original-workspace>/.cache/release-validation/20260907-packaging-01/evidence`.
- Host: macOS 26.6.2, build 25G83, Apple Silicon; Xcode 26.6, build 17F113; Apple Swift 6.3.3. Commands selected `/Applications/Xcode.app/Contents/Developer` with `DEVELOPER_DIR`.
- Snapshot selection: `git ls-files --cached --others --exclude-standard -z`, excluding any `.build`, `.cache`, `.git`, `dist`, `results`, or `DerivedData` path component. It contains **143** source/support files. Ignored downloaded audio/models, prior results, caches, and project compilation output were excluded. The file list, byte sizes, modes, exclusions, and creation time are in [snapshot.json](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz).
- [source.sha256](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz), SHA-256 **`cdaf5d4826d2ba914f20032da6ca5b3e93e2b4b78cdd3890b38faa5019af99d0`**, identifies all copied files. Checks before and after packaging passed for every entry. This report was written after the snapshot and is not part of it.
- [build-inputs.sha256](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz), SHA-256 **`37737d2dfa68a7d470db9e7f8fb836c832672648022ec83a507df1ad9fd4fde0`**, identifies **60** package/source/resource/script files, including the local core package. Those files also matched the original workspace at the recorded comparison; documentation may continue to evolve. See [original-source-comparison.json](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz).
- Existing SwiftPM `checkouts`, `repositories`, and binary dependency `artifacts` were copied into the snapshot's fresh `.build`; no compiled project objects, executables, modules, or build database were copied. Only absolute paths in the copied SwiftPM `workspace-state.json` were remapped to the snapshot. No dependency installation was needed.
- The copied FluidAudio checkout is clean and matches `Package.resolved`: **0.15.6 / `4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b`**. [dependencies.sha256](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz), SHA-256 **`984bdfd994ce9a7af3168c5e99ecb607b2a2031185fcd46c85b31a4336ef0b8e`**, identifies copied dependency source and binary-artifact files. [dependencies.json](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) records this separation from project build products.

## Commands and results

Times below are UTC. Local Europe/Belgrade time was UTC+02:00. Each linked JSON records the exact argument array, working directory, start/end times, duration, and exit status; full stdout/stderr is retained in its log.

| Operation | UTC start–end | Elapsed | Exit | Evidence |
| --- | --- | ---: | ---: | --- |
| Debug build | 13:11:41–13:12:02 | 21.442 s | 0 | [debug-build.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz), [exact command](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| Release build | 13:12:28–13:13:27 | 59.051 s | 0 | [release-build.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz), [exact command](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| Release app and ZIP | 13:14:30–13:15:27 | 56.760 s | 0 | [package.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz), [exact command](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| Final artifact inspection | 13:16:19–13:16:19 | 0.468 s | 0 | [artifact-inspection-run.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz), [exact command](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| Final snapshot hash check | 13:18:11–13:18:11 | 0.026 s | 0 | [final-source-hash-check.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz), [exact command](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |

The build commands ran from the snapshot root:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c debug --arch arm64 --product MeetingCopilot --disable-automatic-resolution --skip-update --jobs 4
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --arch arm64 --product MeetingCopilot --disable-automatic-resolution --skip-update --jobs 4
env -u MEETINGCOPILOT_NOTARY_PROFILE -u MEETINGCOPILOT_OAUTH_CLIENT_ID -u MEETINGCOPILOT_BUNDLE_ID MEETINGCOPILOT_SIGN_IDENTITY=- DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/package.sh
```

`script/package.sh` and `script/build_and_run.sh` were copied unchanged. Packaging invokes `--build-only`, which still terminates processes named `MeetingCopilot`; the coordinating task had stopped the owned app and confirmed packaging could proceed. The packaging command did not launch the app. The package script rebuilt Release using its normal defaults, then staged, signed, verified, and archived the result. Swift emitted a deprecation warning for `--skip-update` in the two explicit builds; both succeeded.

## Bundle, signatures, and archive

| Inspection command, relative to snapshot unless absolute | Exit | Raw output |
| --- | ---: | --- |
| `/usr/bin/plutil -lint dist/MeetingCopilot.app/Contents/Info.plist` | 0 | [bundle-plist-lint.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| `/usr/bin/lipo -archs dist/MeetingCopilot.app/Contents/MacOS/MeetingCopilot` | 0 | [architecture.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| `/usr/bin/file dist/MeetingCopilot.app/Contents/MacOS/MeetingCopilot` | 0 | [file-type.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| `/usr/bin/xcrun vtool -show-build dist/MeetingCopilot.app/Contents/MacOS/MeetingCopilot` | 0 | [minimum-os.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| `/usr/bin/otool -L dist/MeetingCopilot.app/Contents/MacOS/MeetingCopilot` | 0 | [dynamic-dependencies.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| `/usr/bin/otool -l dist/MeetingCopilot.app/Contents/MacOS/MeetingCopilot` | 0 | [load-commands.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| `/usr/bin/codesign -dvvv --entitlements :- dist/MeetingCopilot.app` | 0 | [signature-details.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| `/usr/bin/codesign --verify --deep --strict --verbose=2 dist/MeetingCopilot.app` | 0 | [signature-verify.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| `/usr/sbin/spctl --assess --type execute --verbose=2 dist/MeetingCopilot.app` | 3 | [gatekeeper-assess.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| `/usr/bin/unzip -t dist/MeetingCopilot-1.0.0-macOS-arm64.zip` | 0 | [archive-integrity.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| `/usr/bin/ditto -x -k dist/MeetingCopilot-1.0.0-macOS-arm64.zip <original-workspace>/.cache/release-validation/20260907-packaging-01/evidence/extracted` | 0 | [archive-extract.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |
| `/usr/bin/codesign --verify --deep --strict --verbose=2 <original-workspace>/.cache/release-validation/20260907-packaging-01/evidence/extracted/MeetingCopilot.app` | 0 | [extracted-signature-verify.log](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) |

[artifact-inspection.json](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) and [inspect_artifacts.py](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) retain the content checks and their implementation. The final inspector exited 0. Its first attempt exited 1 because a source-path assertion incorrectly included `otool`'s heading, which prints the inspected binary's absolute path; the assertion was corrected to inspect dependency entries. No source or artifact changed for that repair; [inspection-attempt1.json](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) preserves the failure classification.

Verified bundle facts:

- Mach-O executable **arm64 only**; `LC_BUILD_VERSION` reports **minos 15.0**, SDK **26.5**. `Info.plist` also sets minimum macOS **15.0**. No Intel or universal build is claimed.
- Bundle identifier `local.meetingcopilot.app`, version `1.0.0` / build `1`, package type `APPL`, executable `MeetingCopilot`, `NSApplication`, and menu-bar mode `LSUIElement=true` are present. Microphone, screen/audio-capture usage descriptions and the OAuth callback URL scheme are present. No OAuth client ID was injected for this artifact.
- `codesign` reports **`flags=0x10002(adhoc,runtime)`**, `Signature=adhoc`, no TeamIdentifier, and `com.apple.security.device.audio-input=true`. Strict/deep verification passes for the staged app, extracted app, and final copied app. There is no App Sandbox entitlement. This inspection proves signing metadata and integrity, not permission grants or runtime capture behavior.
- Gatekeeper assessment returns **3 / rejected**. No Developer ID identity or notarization profile was supplied. No notarization submission, stapling, or notarized-distribution claim was made.
- `Info.plist`, `AppIcon.icns`, the model manifest, and **9** files under `Contents/Resources/Licenses` match source bytes. License payloads cover FluidAudio, NemoTextProcessing plus Rust inventory/licenses and upstream notice, Parakeet attribution, fastcluster, and VBx. This checks staged provenance/contents, not legal approval.
- `Contents/Resources/FluidAudio_FluidAudio.bundle` contains the dependency's two optional LuxTts lexicon resources. No executable helper or embedded dynamic framework is required by the inspected app. All recorded dynamic dependency entries are absolute `/System/Library` or `/usr/lib` paths.
- The pinned model manifest contains **21** unique model-file entries totaling **483,105,645 bytes** and matches the source manifest SHA-256. The archive contains no model weights. Model download, verification, and loading remain separate app operations.
- ZIP entry paths are relative without parent traversal; `unzip -t` passes. `ditto` extraction into the evidence directory preserves all **16** packaged files, their SHA-256 values, byte sizes, and modes. Extracted signature verification passes.

## Runtime-path boundary

The binary has no dynamic library entry or runpath referencing the original workspace or isolated source directory. Its runpaths are `/usr/lib/swift`, `@loader_path`, and an Xcode Swift-toolchain directory; none of its recorded library entries uses `@rpath`, so the inspected dependency list does not require that Xcode runpath. This is static evidence, not proof from execution on a Mac without Xcode.

The app obtains `model-manifest.json` through `Bundle.main` in `Contents/Resources`; `PreferencesStore.defaultDirectory` uses the user's Application Support directory. `LocalSpeechModelCache` loads the verified models through explicit local URLs and constructs `AsrModels` directly. These active application paths do not locate resources through a source checkout.

The pinned FluidAudio generated `Bundle.module` accessor does contain a build-directory fallback and an app-root candidate, while the optional resource bundle is staged in `Contents/Resources`. Only the unused `TTS/LuxTts/G2p/LuxTtsG2p.swift` references `Bundle.module` in the pinned dependency sources. The meeting ASR path does not use it. Consequently, the evidence supports independence of the active app/ASR paths statically; it does **not** claim that every unused SDK feature would work after relocation.

A copied/extracted app was **not launched** by this task, so relocated startup, resources during live transcription, a clean user account, macOS 15 execution, and a machine without Xcode remain **NOT TESTED** here.

## Delivered local artifacts

With coordination approval, the previous `dist/MeetingCopilot.app` was preserved at `<original-workspace>/.cache/release-validation/20260907-packaging-01/prior-artifact/MeetingCopilot.app`. The verified app and ZIP were then copied into the original `dist` at **2026-09-07 13:17:18 UTC**, with all file hashes checked again and the copied signature verified. No source file was moved or reset. See [final-artifact-copy.json](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz).

| Artifact | Size / identity |
| --- | --- |
| [MeetingCopilot.app](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-1.0.0-macOS-arm64-original.zip) | 22,971,967 file bytes, 16 files |
| App executable | 21,093,872 bytes; SHA-256 `a27d0effa01c0206a337d2e63597b45c884944cc1eb230ef18d912bea3b22eb1` |
| [MeetingCopilot-1.0.0-macOS-arm64.zip](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-1.0.0-macOS-arm64-original.zip) | 10,961,243 bytes; SHA-256 `58b46c4e4773662a5bec9f4f89f1f9beb4cd1c415122446a21b5739218e3e1a7` |
| [ZIP checksum](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-1.0.0-macOS-arm64-original.zip.sha256) | Uses the archive basename for verification from `dist` |
| [app-files.sha256](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) | Manifest SHA-256 `10a2c49f4f5f754c7963e2d17fc449d2cc71dcdffe8834329591de04dc6303a0` |

This report identifies this immutable snapshot and these bytes. Any later production-source change requires a fresh package and updated artifact hashes before it can inherit this evidence.


## Clean Git checkout build — commit ef16d1c

A real local Git clone at `<original-workspace>/.cache/clean-checkout-validation/ef16d1c/source` checked out exact commit `ef16d1c707226a56cd597f684325be27f41f4acf` with detached HEAD. All **184 tracked files** matched that commit's blobs; Git status was clean before and after both builds, and the final file-hash check passed. The tracked-files manifest SHA-256 is `0481bf94fdbdd69c01fe94b9f3d2b16be11991e3532327601efeba1451c4d844`. All **60 packaging inputs** matched the earlier packaged snapshot and current workspace.

| Build | 7 September 2026 UTC interval | Elapsed | Exit |
| --- | --- | ---: | ---: |
| debug-build | 14:46:11–14:46:34 | 22.694 s | 0 |
| release-build | 14:47:02–14:48:04 | 61.477 s | 0 |

Both used stable Xcode and `swift build -c <configuration> --arch arm64 --product MeetingCopilot --disable-automatic-resolution --skip-update --jobs 4`. Only verified dependency checkouts/repositories/binary artifacts were copied; project objects/modules/executables were rebuilt. No package script, app/UI/model operation, test, or remote push was run. Exact commands, times, exits, raw-log paths, binary hashes, source/dependency comparisons, and the checkout path are in [clean-checkout-verification.json](../Benchmarks/results/clean-checkout-verification.json).

The separate four-hour soak helper **34454** was observed between builds and after both; its recorded start time preceded either build. The compilation intervals above overlap that soak, so its host was **not idle** during those intervals. The soak snapshot, files, and process were not changed by this task.

## Publication packaging

The public preview ZIP adds the owner-selected Apache-2.0 `LICENSE` and project `NOTICE` beside the app. Every original archive entry, including the signed app, remains byte-identical. The original pre-publication ZIP is preserved as `MeetingCopilot-1.0.0-macOS-arm64-original.zip`; its historical hash above remains valid. Current release checksums identify both archives. Future packaging includes these license files automatically.
