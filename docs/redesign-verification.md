# Unified panel verification — 2026-09-09

The subsequent graphite glass and Actions update is tracked in the [glass verification ledger](glass-verification.md). The results below describe the preceding implementation.

This ledger separates implementation, local runtime tests, controlled workload evidence and external acceptance. Earlier preview evidence remains in its original files and is not a claim about the redesigned panel.

## Current implementation

- One `ShellWindowController`, retained native page hosts, internal navigation/choices/confirmations and one owner for file sheets.
- Schema 3 preferences with legacy migration; independent geometry lock, frozen answer and presentation visibility.
- Native selectable answer/transcript text, scoped screen consent and inline region selection.
- `PresentationCoordinator` owns the stream, one-slot mailbox, compositor and output window. Source and visibility revisions reject stale state; source interruption and system UI neutralize the output.
- ScreenCaptureKit queue depth is 3. The application capture mailbox holds one newest source frame. The interface bitmap is refreshed at most every 100 ms during normal streaming and immediately on visibility changes. There is no outbound audio or AI image request from this coordinator.

## Completed local evidence

- Domain suites: **49 tests** passed in Debug and Release.
- Application regression suites: **179 passed, 9 opt-in skips** in each of Debug and Release (**188 collected**). A separate opt-in native run passed **13 checks**. [Configuration identities and results](../Benchmarks/results/redesign-verification.json).
- The 46 rendered page/state screenshots passed exact 720 × 520 and 960 × 700 size assertions; see the [gallery](assets/shell/README.md).
- Native focus checks exercised passive streaming and explicit question focus/hide. Native registration checks exercised conflicting/reconfigured shortcuts.
- The output readback check exercised rectangle markers and antialiased native answer glyphs, including their removal after Hide, selected-window and display sources, rapid page/visibility changes, and neutralization.
- The isolated **1,800-second** controlled workload **passed**: **38,416 published frames**, active output through completion, **zero dropped audio and zero gaps** on both sources, **105 observed answers**, **13,778,944 bytes** warm-to-final RSS growth, **1,066,106,880 bytes** sampled RSS peak, and **27.85 ms** teardown with no session tasks or recorded-provider jobs left. [Raw result](../Benchmarks/results/presentation-soak-1800s.json).

After this workload, remaining changes were limited to reopening the same panel, restoring geometry using display UUIDs, avoiding redundant window-style assignments, and rejecting capture sources when ownership cannot be identified. These boundary changes received the final regression/native checks; they are not represented as an additional 30-minute run.

## Automated verification

Run the existing project pipeline for both configurations:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/FreelyCore -c debug
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-tests --arch arm64 -Xswiftc -enable-testing
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 script/ci_tests.py debug
# Repeat with -c release and ci_tests.py release.
```

`Tests/Shell` covers migration of both previous schemas, exact default bindings, invalid geometry, off-screen clamping, native selection across corrections, navigation/draft retention, file-sheet cancellation, separate lock/freeze semantics, excerpt gaps, bounded frame storage, neutral frames, fitting and marker exclusion. The snapshot harness checks both exact sizes for all pages plus error, preparation, generation, incomplete code, large text, frozen replacement, action list, choice list and end confirmation.

Local native checks are opt-in:

```sh
./script/capture_fixture.sh
FREELY_PRESENTATION_TEST=1 FREELY_FOCUS_TEST=1 FREELY_SHELL_SNAPSHOTS=1 \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --arch arm64 --no-parallel \
  --filter 'PresentationRuntimeTests|OverlayFocusTests|ShellSnapshotTests'
```

The capture test uses the separate public CaptureFixture window and a display stream, adds a magenta marker to the actual AppKit panel, toggles visibility across all pages, and checks newly published pixels after hide, source change and pause. It does not send those frames to a meeting service. Local system authorization is required; a permission failure is not a passing capture test.

Snapshot PNGs are written to `/tmp/freely-shell-snapshots` by default. The guide uses synthetic fixtures from this run. Passive focus evidence is recorded separately in `Benchmarks/results/shell-passive-focus.json`.

## Preserved first-run failures

The first 1,800-second run is preserved in [presentation-soak-1800s-first-interrupted.json](../Benchmarks/results/presentation-soak-1800s-first-interrupted.json), with [its loaded executable and input identities](../Benchmarks/results/presentation-soak-first-inputs.json). It **failed** the combined gate because video was no longer active at the end. Both audio sources had zero drops/gaps, 105 answers were observed, warm-to-final RSS grew by 1,998,848 bytes, and session/provider work was cleaned up. Those successful components do not make the combined test pass.

The system logged ReplayKit capture-connection interruption for that test process at 01:09:17 local time. Concurrent native capture checks were running then. The ultimate cause of that service interruption is not established. Subsequent native preview requests also stalled. These failures are preserved rather than attributed to successful receiver acceptance.

Later fixes use a layer-backed output view so window-server capture observes updates behind other windows, and a short owned stream for local presentation previews. A separate readback test captures the actual output window and checks both rectangle markers and native NSTextView glyphs before and after hiding. That local check passed; it is not a meeting-recipient test. Temporary preview failures were observed during the system capture interruption; the later isolated run and native readback succeeded without restarting system services.

## Thirty-minute controlled workload

The optional presentation workload extends the existing integration soak with a real ScreenCaptureKit stream of CaptureFixture and the production compositor. Audio is paced synthetic English speech supplied to both real local STT pipelines. Generation uses the existing recorded provider. A hidden production SwiftUI/AppKit host supplies the interface bitmap. No live microphone, live Grok request or recipient meeting is represented by this workload.

```sh
./script/prepare_redesign_soak.sh
./script/capture_fixture.sh
FREELY_SOAK=1 FREELY_SOAK_SECONDS=1800 FREELY_SOAK_UI=1 FREELY_SOAK_PRESENTATION=1 \
  FREELY_SOAK_CORPUS="$PWD/.cache/redesign-soak-corpus" \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --arch arm64 --no-parallel --filter IntegratedSoakTests.realTimeDualSourceLocalProcessing
```

The run requires the already verified local model installation and records `Benchmarks/results/presentation-soak-1800s.json`. Check actual completion, both source counts/drops/gaps, frame counts, rendering time, memory samples and teardown. Development builds and focused capture tests overlapped the first run. The isolated rerun uses the corrected output implementation and runs without concurrent ScreenCaptureKit tests. The source/executable identity is recorded in [presentation-soak-inputs.json](../Benchmarks/results/presentation-soak-inputs.json). Neither run is a controlled latency comparison.

## External acceptance still required

| Check | Status | Evidence required |
| --- | --- | --- |
| Meet / Chrome recipient | Not conducted | Chrome/macOS versions, selected Freely Presentation window, receiver recording and marker checks |
| Zoom / macOS recipient | Not conducted | Zoom/macOS versions, selected window, receiver recording and marker checks |
| Teams / macOS recipient | Not conducted | Teams/macOS versions, selected window, receiver recording and marker checks |
| Physical multi-monitor disconnect, Spaces and fullscreen | Not conducted | Real display/Space transitions, reachability and focus checks |
| Full VoiceOver journey | Not conducted | Spoken labels, focus order and all primary actions on the actual panel |
| Live 30-minute audio/STT/Grok/receiver meeting | Not conducted | Provider and receiver versions, capture metrics, no new gaps, bounded queues and clean stop |

The desktop UI driver initially timed out on the accessory panel. In the final packaged Debug app, readiness and the panel screenshot were readable after adding the reopen route. Command–K was observed opening the internal action list in the final Release app. Other actions were rejected by the driver's state-change guard while the user changed settings, so a complete packaged-app journey is not marked passed. Readiness initially reported missing microphone authorization; the later Audio & Speech view showed permission Allowed. No live meeting was started by the agent. The native AppKit harness separately provides rendering, focus, key registration, source filtering and output-window readback evidence.

Locally installed versions were Zoom **7.1.5 (84650)** and Teams **26163.407.4839.8659**. Chrome was not found in `/Applications`; no test receiver or meeting URLs were supplied. These inventory facts do not establish a receiver result.

The presentation guarantee is not accepted until all three agreed receiver applications pass. Local source previews and synthetic compositor tests are insufficient by themselves.
