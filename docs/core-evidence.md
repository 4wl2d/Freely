# CopilotCore evidence

CopilotCore contains platform-independent conversation/session value types and actor-owned state. The separate `CopilotCoreBenchmarks` executable uses macOS task accounting to measure its own resident memory. It is not part of the application product and does not load speech models, access audio devices, or make API requests.

## Reproduction

The verified toolchain is Xcode 26.6 (`17F113`), Swift 6.3.3, macOS 26.6.2 (`25G83`), Apple Silicon. Application-owned core code uses Swift 6 language mode and complete concurrency checking.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/CopilotCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release --package-path Packages/CopilotCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run -c release --package-path Packages/CopilotCore CopilotCoreBenchmarks --seconds 14400 --output Benchmarks/results/core-replay-4h.json
```

Debug and Release each passed 47 Swift Testing tests. The XCTest compatibility runner prints “0 tests”; the subsequent Swift Testing summary is the authoritative count. No test requires a microphone, permission prompt, download, or API credential.

## Verified behavior

| Area | Evidence |
| --- | --- |
| Transcript reconciliation | Partial replacement, finalization, duplicate and older-revision rejection, explicit final correction, retraction, deterministic timestamp order, invalid time/identity rejection |
| Bounded retention | Age, segment count, byte count, gaps, retraction tombstones, source watermarks; 600-turn compacting regression and accelerated four-hour replay |
| Epoch ownership | Old source/session callbacks rejected; late stop/start cannot move the actor back to an old epoch; changing decoder epochs preserves historical provenance and does not retire new decoder sequence numbers |
| Turns | Multi-segment construction, 300 ms boundary stability, interruptions, stable IDs across late prepend/removal, monotonically increasing revisions separate from source fingerprints |
| Questions | Interrogatives, imperative/comparison requests, follow-up chains, local-source exclusion, false-trigger fixtures, cosmetic versus negation/operator edits, correction propagation into follow-up antecedents |
| Missing/corrected evidence | Gap-overlapping automatic intent invalidation; retracted antecedents removed from subsequent context; stale summary commits rejected after correction, source change, or stop |
| Context | All text allocations, model/output/safety reserve, active-question rejection instead of silent truncation, selected context only, source/summary/AI-suggestion provenance, explicit omissions and extractive fallback |
| Generation | A→B supersession, late A text/terminal events, session/revision fences, partial interrupted answers, output byte limit, pin during an active stream, one latest pinned replacement |
| Lifecycle | Stop during preparation, repeated stop, rapid restart, pause/resume/recovery, stale readiness, independent source failures |
| Visual values | Selection change, consent disable/re-enable, source disappearance, session/question revisions, stale image, byte/dimension limits, mixed backing-scale crop geometry |
| Arbitration | Manual priority, one newest pending intent, stale-intent expiry, shared starts-per-minute cap, provider backoff, bounded retry decisions |
| Integrated replay | Two transcript sources → reconciliation → question → selected bounded context → test-only scripted text stream → observable answer state |

The scripted provider is confined to the test target. It proves deterministic state behavior; it is not evidence of Grok availability, quality, or latency.

## Retention and invalidation details

The transcript retains the newest ten minutes subject to a 2,000-segment and 2 MiB text cap. Question/suggestion histories have count and byte caps. The core keeps at most 128 explicit gaps, 2,000 retraction tombstones, and 2,000 question-revision counters. Stable ticks reuse immutable snapshots instead of rebuilding unchanged text. The native owner must pass its captured epoch to `tick(now:sessionEpoch:)` and maintain source epochs independently.

Retraction of an existing segment derives its source sequence. A retraction arriving before its insert must supply `sequence`; otherwise it is rejected as invalid because a bounded store could not preserve a retirement watermark. Retired tombstone IDs advance a source sequence watermark. A decoder change clears that source's current watermark while retaining historical text from older decoder epochs.

An `AudioDiscontinuity` has a covering start/end interval and optional measured `lostDuration`. `droppedDuration` uses that measured sample duration when provided. Coalesced disjoint drops can therefore cover a long wall-clock span without falsely counting the whole span as missing audio. Invalid negative, nonfinite, or greater-than-span measured durations are rejected.

Semantic summaries carry source/stream/segment/revision/time references and a fingerprint. Only one request can be pending. `commitSummary` rejects changed inputs or obsolete sessions/source selections. A newly reported gap invalidates an intersecting pending or committed summary; new summaries omit affected segments. Extractive fallback is bounded and explicitly identifies incomplete earlier context. Live semantic summary quality requires separate provider evaluation.

## Benchmark results

Raw preliminary results are in `Benchmarks/results/core-replay-4h-before-optimization.json`; the current implementation's run is in `Benchmarks/results/core-replay-4h.json`. The fixture is `two-source-domain-v1`: one local statement and one remote statement every two seconds of simulated meeting time, with a clear remote question every minute. It processes 14,400 transcript events and 7,200 stable ticks, builds 240 foreground contexts, repeatedly compacts history, and injects 100 obsolete callbacks after a stop/restart.

The preliminary run exposed repeated Unicode counting in echo annotation and repeated text normalization in the context-sort comparator. Normalization now happens once per candidate turn; unchanged ticks are cached. The raw files contain every metric's sample count, p50/p95/maximum, retained collection peaks, and resident-memory growth samples. The benchmark runner retains all measured timing samples within its explicitly bounded requested run (maximum 24 hours of simulated input).

| Operation | Preliminary p50 / p95 (ms) | Final p50 / p95 (ms) | Final maximum (ms) |
| --- | ---: | ---: | ---: |
| Transcript apply + question detection | 15.335 / 17.239 | 9.077 / 9.883 | 14.289 |
| Bounded foreground context construction | 220.297 / 235.491 | 5.298 / 5.659 | 6.582 |
| Unchanged stable tick | 0.010 / 0.021 | 0.010 / 0.018 | 0.059 |

The final replay completed in 130.91 seconds of wall time. All measured invariants passed: 240/240 expected automatic questions, 100 obsolete callbacks rejected, maximum 601 retained segments, 43,230 transcript bytes, 20 question records, and 5,498 estimated input tokens. Resident memory was 9.41 MiB after ten minutes of simulated warm-up and 10.72 MiB at the four-hour simulated endpoint (growth 1.31 MiB). The machine had 18 logical CPUs and 128 GiB physical memory. These are local core timings and domain-only resident measurements, not speech-to-answer or full-application results.


## Limits of this evidence

- Synthetic English text fixtures do not establish real-speech question precision/recall, word error rate, acoustic echo cancellation, or technical-term recognition quality.
- Cross-source equality and timing only annotate possible loudspeaker bleed; local speech is never destructively suppressed.
- The text estimator charges one estimated token per UTF-8 byte and reserves framing overhead. It is deliberately conservative, not a tokenizer or provider-reported usage. Oversized active questions are rejected with an actionable error.
- Speculation has an experimental disabled-by-default gate and cancellation tests. No measured live latency/cost benefit is claimed.
- An accelerated four-hour domain replay is not a four-hour paced audio/STT thermal soak. Resident memory excludes STT assets and native capture state. Network latency, real provider retry behavior, actual screenshots, native app focus, and native teardown need their own integration evidence.
- The package declares macOS 15 as its deployment minimum. Runtime tests reported here ran on macOS 26.6.2; they do not establish separate macOS 15 runtime coverage.

## Application coordinator integration

The application `SessionCoordinator` and `GenerationCoordinator` now have 32 focused integration tests under `Tests/Session` and `Tests/Generation`. Two additional fixture-reader tests validate exact PCM framing across file boundaries and corrupt/empty input rejection. Their native capture/model/network replacements exist only in test targets; the normal initializer still constructs the real local model cache, native audio capture, ScreenCaptureKit state and configured credential-backed provider.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'GenerationCoordinatorTests|SpeculationCoordinatorTests|SessionCoordinatorTests|SoakFixtureReaderTests'
```

These checks prove that a hundred rapid replacements retain one foreground task and one newest pending intent; queued manual requests survive automatic speech; source pause/resume cannot lose a cancelled task; preparation/native-start/active-inference teardown is awaited; wrong source and source/session epochs are rejected at the callback boundary; stopped sessions retain no application-owned tasks; and summary failures use a cooldown instead of retrying every second. Decoder cleanup happens after the cancelled prediction has quiesced, matching the native backend contract.

Source selection can change while that source is paused, failed or stopped. Running/preparing devices and scopes remain fixed. An ambiguous bundle identifier matching several processes is rejected with an actionable message. Explicit detailed requests and the selected code style use the detailed output allocation and corresponding input reserve. Missing provider usage stays unknown.

Profile, notes, pinned context, style and language changes compare selected values before doing anything. Identical assignments preserve the current request. Material changes synchronously fence/cancel the old payload and clear derived presentation. The next request purges previous AI suggestions that might contain deselected profile details, while preserving actual observed conversation. Profile paragraph selection runs in an owned structured child task outside MainActor.

Screen settings have a synchronous preparation boundary and a session/revision ticket for the asynchronous native commit. A new visual request synchronizes the latest desired mode/selection pair before capture, so it cannot outrun a deferred settings update. Obsolete commits cannot re-enable consent after stop/restart. Selection or consent changes cancel visual work without discarding a queued explicit text-only request.

## Scripted speculation experiment

Experimental speculation is wired through the same generation owner and request-budget path and remains disabled by default. It admits at most one stable clear prefix per turn, keeps all unconfirmed output hidden, reuses only an exact material question revision, and discards changed qualifications. The following paired fixture uses **virtual time and recorded events**, including explicitly supplied usage numbers. It establishes arbitration behavior, not real Grok latency or billing.

| Scripted case | Eligible final question → visible answer | Provider fixture requests | Scripted input / output tokens | Reused / discarded prefixes |
| --- | ---: | ---: | ---: | ---: |
| Disabled | 500 ms | 1 | 100 / 10 | 0 / 0 |
| Enabled, unchanged prefix | 0 ms | 1 | 100 / 10 | 1 / 0 |
| Enabled, changed qualification | 500 ms | 2 | 200 / 20 | 0 / 1 |

`SpeculationCoordinatorTests` prints a `SPECULATION_FIXTURE_METRICS` JSON line when rerun. Live useful-answer improvement and token overhead remain unverified, so the flag is not enabled by this experiment.

## Paced local-processing smoke

`Tests/Soak/IntegratedSoakTests.swift` is opt-in. It verifies licensed PCM checksums, emits exact 320-sample frames on absolute source deadlines, uses the real local model and application coordinators, and substitutes only audio capture and the recorded LLM transport. It samples resident and physical-footprint memory, preserves only bounded counters, measures final memory before teardown, and stops every owned service after success, failure or Swift task cancellation. Runtime source state must contain both transcribing sources; an empty metrics dictionary cannot pass vacuously. It keeps cold-preparation peaks separately and leaves an unavailable warm baseline null.

The first 60-second run completed its requested duration and clean teardown, but **failed the zero-audio-loss criterion**: local audio lost 0.04 seconds despite a maximum queue of 0.08 seconds. Both sources transcribed (15 local and 9 remote retained segments); teardown took 0.000218 seconds with zero owned tasks. This failure is preserved in `Benchmarks/results/integrated-soak-60s-before-ingress-fix.json` and requires a native ingress fix before a passing long soak can be claimed. It is separate from the passing accelerated domain replay above.
