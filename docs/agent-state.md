# Execution state

Updated 2026-09-07. Independent implementation, build, regression, soak and packaging work is complete; the overall Definition of Done awaits external acceptance. [Verification](verification.md) is the detailed status ledger.

## Baseline and completed work

- Existing empty Git repository; branch feature/freely, no unrelated code removed. Native SwiftUI/AppKit app plus FreelyCore. Host: Apple M5 Max, 18 logical CPUs, 128 GiB, macOS 26.6.2 (25G83). Xcode 26.6 (17F113), Swift 6.3.3, SDK 26.5; minimum deployment 15.0 is not separate runtime coverage.
- [Final regression results](../Benchmarks/results/regression-verification.json): application Debug and Release each exited 0, **141 collected / 139 passed / 2 opt-in skips**, 28 suites. Keychain and Carbon registration tests enabled. Core **47 passed in Debug and Release**. The OAuth fixture fix preserves original assertions; temporary production diagnostics were restored byte-for-byte.
- Coordinator correction tests now fence answers after accepted selected-local or selected-summary-source corrections, while ordinary partials/unselected/stale/cosmetic changes and eviction alone preserve valid work. New context/transcript logging is metadata-only. The focused correction handoff passed 36 tests; the later Debug aggregate includes it.
- [Real microphone repeat](../Benchmarks/results/native-microphone-smoke.json) exercised the typed CF-clock fix in a normally launched Release app: 48 kHz default built-in input, 6,564 frames, 10 retained segments, observed dropped duration 0, stop 28 ms and 0 retained segments. No raw audio/text persisted and no cloud request. This binds the recorded binary, not every later package.
- [Passive panel focus](../Benchmarks/results/overlay-passive-focus.json) passed 100 updates at 40 ms cadence without activating itself or becoming key. Kitty retained focus. This is a real production panel/controller in a test process, not fullscreen/Spaces or receiver coverage.
- [STT decision](../Benchmarks/STT/results/backend-selection.json): **FluidAudio 0.15.6 / TDT v3 default variant**, system RMS floor **0.001**, microphone **0.004**. Remote heldout WER **23.38% versus 29.19%** for whisper.cpp; scores were within the frozen tie band, favoring TDT's accuracy/footprint. [STT ledger](stt-gate.md) preserves failed latency objectives, one recognized heldout question, three technical terms and separate synthetic regressions.
- [60 s integrated repeat](../Benchmarks/results/integrated-soak-60s.json) **passed** after SPSC ingress repair: no dropped audio/gaps, 16 local + 9 remote segments, teardown **16.85 ms**, no owned tasks/provider jobs after stop. [Prior 0.04 s loss](../Benchmarks/results/integrated-soak-60s-before-ingress-fix.json) remains **failed**. A later overflow-only sequence-gap fix passed [18 targeted tests](https://github.com/4wl2d/Freely/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz); the 60 s artifact predates that final edge fix.
- [Accelerated four-hour core replay](core-evidence.md) passed bounds and 240/240 questions; it is not a paced audio/thermal soak.
- [Isolated packaging](packaging-evidence.md) completed fresh project Debug/Release builds and ZIP validation. [App](https://github.com/4wl2d/Freely/releases/download/v0.1.0-preview/MeetingCopilot-1.0.0-macOS-arm64.zip) and [ZIP](https://github.com/4wl2d/Freely/releases/download/v0.1.0-preview/MeetingCopilot-1.0.0-macOS-arm64.zip) exist; ARM64/minimum 15.0, resources, strict signatures and extraction hashes/modes passed. **Ad hoc signed, hardened runtime, not notarized; Gatekeeper rejected.** Packaging itself did not launch it; root subsequently launched the copied app and checked its subscription-first setup and native overlay controls. [UI evidence](../Benchmarks/results/packaged-ui-smoke.json).

- [Clean Git checkout](../Benchmarks/results/clean-checkout-verification.json) of ef16d1c passed Debug (22.694 s) and Release (61.477 s), with a clean tree before/after and all 184 files equal to commit blobs. All 60 production build inputs match the packaged snapshot. The build intervals overlap the soak and are recorded; no concurrent model jobs ran.

## Completed paced soak

The [four-hour result](../Benchmarks/results/integrated-soak-14400s.json) passed, with the same process followed to exit 0. Processing lasted 14,400.000220 s and each source offered 14,400.06 s. No dropped audio, gaps or session errors; maximum 167 segments / 9,736 bytes. RSS warm/final 658.516/669.906 MiB, growth 11.391 MiB under 128 MiB; sampled peak 670.641 MiB. Total teardown 69.206 ms; owned tasks/provider jobs 0 afterward. Full source-duration, memory and cleanup checks are recorded in [run metadata](../Benchmarks/results/integrated-soak-14400s-run.json).

The local decoded-window coverage was only 664.84 s versus 12,837.96 s remote. The workload proves sparse local inference alongside sustained remote inference, not dense dual speech or quiet-local accuracy. Hidden UI text peaked at 200 bytes; no long-answer/visible UI load. Recorded provider cancellations were zero. No actual capture or live provider was involved; development builds overlapped the run. Preserve these boundaries, the original 60 s failure and all prior failed test traces.

## User steering and external boundaries

- Subscription OAuth is primary, API key optional. Own-client PKCE code/tests exist, but Freely still lacks its provider-issued registration and verified custom subscription route/entitlement. Do not borrow OpenCode/Grok Build identity or infer entitlement from those integrations.
- No live authorized Grok text or transcript-plus-image request has run. Continue independent work while registration/account prerequisites remain unavailable.
- The current recorded system-capture attempt failed with ScreenCaptureKit -3801 despite prior visible permission grants. Microphone works independently; simultaneous real capture and actual visual acquisition remain unverified.
- Browser/native meeting receiver, capture visibility, fullscreen/Spaces, display-change and physical lock/sleep matrices remain untested. com.apple.screenIsLocked is an undocumented distributed notification, not a stable Apple contract.
- No usable Developer ID/notarization credentials were established. Local package integrity is verified; notarization, clean-account and macOS 15 runtime checks are not. Copied-app startup in the existing account has been inspected; physical hotkey delivery remains unverified.

## Resume prerequisites

Wait for the current app's native capture authorization and a supported, usable xAI connection. Then run separate live text/image checks and the real simultaneous-source/browser/native-call/display matrix. Existing source, tests and packaged binary need not be rebuilt unless implementation changes. Do not rerun the completed four-hour fixture soak merely because a prior polling handle is closed.
