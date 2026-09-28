# Graphite glass and Actions verification — 2026-09-09

This ledger covers the graphite glass / Raycast-style Actions update on top of the existing unified-panel working tree. The [earlier redesign ledger](redesign-verification.md) retains its own results. Receiver acceptance remains separate.

## Implementation

- `PanelBackdrop` owns an active, behind-window `NSVisualEffectView`, a 75% graphite shade and rounded clipping. It is a sibling of the transparent SwiftUI content host. The window's alpha remains 1; text and buttons are not faded.
- The answer keeps its question field at the top, including during errors, and uses the full remaining content area. The footer has status, Copy and Actions. Lock, Freeze, Detailed, retry/clear, size, independent source pauses, presentation visibility and section navigation are in Actions.
- Actions is 340 points wide, at most 360 high, and constrained inside the window. It overlays the retained page. Search matches titles and keywords; unavailable rows include reasons. Native search fields acquire focus in a nonactivating panel. Local Command shortcuts use physical key positions, including when the input layout is Russian. Actions and selectors share highlight, arrow/Enter handling, scroll-to-selection and focus bookmarks, including AppKit's shared field editor.
- The question draft is separate from the displayed question. Incoming answers and rejected submissions preserve it. The native answer view restores selection from the immutable prior model text, avoiding a mutable `NSTextStorage` bridge during replacement.
- Existing v3 settings default `translucentBackground` to true. Profiles, shortcuts, per-display geometry, answer font and connection preferences survive decoding unchanged. False round-trips explicitly.
- Reduce Transparency forces the opaque backdrop. Reduce Motion disables native window transitions; SwiftUI page and popup changes do not animate.
- Presentation captures only the content host and draws an opaque graphite backing below it. The local blur is never cached. Existing source filters, visibility/source revisions, neutralization and cancellation remain in place.

## Regression and native evidence

Final configuration identities, counts and log hashes are recorded in [glass-verification.json](../Benchmarks/results/glass-verification.json).

| Check | Result |
| --- | --- |
| Debug domain and application regression | 49 domain + 184 application tests passed; 15 opt-in skips (199 collected) |
| Release domain and application regression | 49 domain + 184 application tests passed; 15 opt-in skips (199 collected) |
| Native keyboard / retained state / snapshot / capture checks | 10 passed; 5 keyboard/state checks repeated after the input-layout fix; 1 additional system-accessibility run passed |
| Packaged Release keyboard journey | Passed Actions focus, Command–K, search/Enter, arrows, disabled-action rejection, multiline draft, Esc focus return, Command–W and same-page reopen |
| 30-minute combined workload | Stopped at user request after about 15 minutes; not a completed soak |

The native checks exercise:

- Passive-show → Actions → native search focus; no activation from passive streaming.
- Search by keywords, arrows, Enter, disabled action rejection, Esc and return to the question cursor.
- Selector arrows without commit, Enter commit, empty search results, cancellation and restoration of the original shared field-editor owner.
- Enter versus Shift–Enter in the question and rejection without losing the draft.
- Long-answer selection and scroll across Actions, page navigation, Hide and replacement with an inserted preamble.
- v3 migration, user geometry, independent lock/freeze and opacity fallback.
- Both exact sizes for every page plus errors, preparation, incomplete code, enlarged text and frozen replacement.

See the [screenshot gallery](assets/glass/README.md). Content snapshots are rendered synthetic fixtures on the opaque presentation backing. Separate desktop images are actual ScreenCaptureKit display crops over controlled public light/dark backgrounds. The interior luminance check excludes corners and shadows; content snapshots must be byte-identical across both backgrounds. See [pixel evidence](assets/glass/desktop-evidence.json).

A desktop-independent or window-filtered capture can replace the native glass with a solid surface. Such a capture is not used to judge local translucency. The local appearance check therefore captures the panel's display rectangle over the controlled backdrop.

The output test captures the actual **Freely Presentation** window and verifies native magenta glyph markers, visible Actions, and their removal from new frames after Hide. It also checks selected-window and display sources, repeated page/visibility changes, source loss and neutralization. The source is selected by both its fixture bundle and exact public window title, avoiding unrelated helper windows owned by the same process. [Actions readback](assets/glass/presentation-actions-readback.png) · [Hidden readback](assets/glass/presentation-hidden-readback.png).

System Settings was used to enable **Reduce Transparency** and **Reduce Motion** temporarily. The live panel switched to a solid surface. A native check observed both system flags, hidden blur, disabled window animations, alpha 1 and focused popup search; see [accessibility evidence](../Benchmarks/results/glass-accessibility.json). Both system options were restored to their original off values afterward.

The packaged Release journey used individual keyboard events and accessibility text-field assignment for search. The desktop driver's `typeText` transport was unreliable in the active input layout; it is not counted as a passing text-injection method. Native events and manual field focus demonstrated typing, newline insertion, refusal without draft loss, highlighting, disabled-action rejection and restored focus. No live meeting was started.

## Original visual/regression reproduction

For daily work use `./script/harness.py start`. The explicit visual commands below open test windows.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/FreelyCore -c debug
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --build-tests --arch arm64 -Xswiftc -enable-testing
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 script/ci_tests.py debug
# Repeat with -c release and ci_tests.py release.

./script/capture_fixture.sh
FREELY_GLASS_TEST=1 FREELY_GLASS_CAPTURE=1 FREELY_PRESENTATION_TEST=1 \
FREELY_FOCUS_TEST=1 FREELY_SHELL_SNAPSHOTS=1 \
FREELY_SHELL_SNAPSHOT_DIR="$PWD/docs/assets/glass" \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --skip-build --arch arm64 --no-parallel \
  --filter 'GlassNativeTests|GlassDesktopCaptureTests|PresentationRuntimeTests|OverlayFocusTests|ShellSnapshotTests'
```

Native capture tests require existing local screen-capture authorization. Run them serially and without competing capture tests.

## Interrupted workload and background replacement

The new background Debug profile passed 49 core and 185 application checks (15 opt-in skips) in 13.2 seconds including the incremental build; cancellation was verified separately. [Harness evidence](../Benchmarks/results/harness-verification.json).

Routine development now uses the [background harness](testing-harness.md): no visible output, synthetic capture frames, bounded duration, low priority and explicit stop. The actual ScreenCaptureKit adapter and the in-memory adapter share the same coordinator and compositor. Real output readback was not repeated after this capture-boundary extraction, to avoid interrupting desktop work; it remains an explicit visual check.

The requested 30-minute run was stopped because its visible presentation window interfered with desktop work. It is not counted as a passing soak. Background harness work supersedes a long rerun.

The original workload extends the existing controlled workload with the actual 720 × 520 SwiftUI/AppKit shell, alternating Actions visibility every 10 seconds, search filtering and highlighted-row movement. Both real local STT pipelines process paced synthetic English speech. Generation uses the recorded test provider. Video uses a real ScreenCaptureKit stream of the named public CaptureFixture window and the production compositor. The hidden UI host never initializes application persistence or credentials and never becomes visible/key/main.

```sh
./script/prepare_redesign_soak.sh
./script/capture_fixture.sh
FREELY_SOAK=1 FREELY_SOAK_SECONDS=1800 FREELY_SOAK_UI=1 FREELY_SOAK_PRESENTATION=1 FREELY_SOAK_NATIVE_CAPTURE=1 \
FREELY_SOAK_RESULT_NAME=glass-soak-1800s.json \
FREELY_SOAK_CORPUS="$PWD/.cache/redesign-soak-corpus" \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --skip-build --arch arm64 --no-parallel \
  --filter IntegratedSoakTests.realTimeDualSourceLocalProcessing
```

The new result uses its own filename; preceding runs are preserved. Inspect actual duration, source counts/drops/gaps, UI action layouts, received/published frames, resident memory and teardown. The workload is not a live microphone/Grok/receiver meeting or a controlled performance comparison with an earlier layout.

## External acceptance

Meet/Chrome, Zoom/macOS and Teams/macOS recipient checks are **not conducted** and remain open. Each needs receiver recordings and its own visibility/text checks. Full VoiceOver, physical display disconnect/Spaces/fullscreen journeys and a live end-to-end meeting are also separate from the local harness. Local capture/readback results do not establish recipient acceptance.
