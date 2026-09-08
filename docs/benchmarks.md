# Benchmarks

Machine: Apple M5 Max, 18-core CPU, 128 GiB; macOS 26.6.2 (25G83), arm64. Stable Xcode 26.6 (17F113), Swift 6.3.3. STT runs use Release builds on AC power with thermal state recorded where available. Other development apps were present; this is not a fully isolated laboratory environment.

## Domain replay

`Benchmarks/results/core-replay-4h.json` contains 14,400 events representing 4 h of conversation, 240/240 expected questions and 100 rejected stale callbacks. Actual replay time was 130.91 s; this is explicitly accelerated and contains no native audio/model/network processing.

| Metric | p50 | p95 |
| --- | ---: | ---: |
| Transcript reconciliation | 9.077 ms | 9.883 ms |
| Context construction | 5.298 ms | 5.659 ms |
| Stable tick | 0.00975 ms | 0.01771 ms |

Maximum retained state: 601 segments, 43,230 transcript bytes, 20 questions, 5,498 estimated context tokens. RSS after 10 min simulated warm-up was 9.406 MiB and final 10.719 MiB (+1.313 MiB). This does not measure resident STT assets, real-time thermals or internet latency.

A retained baseline records context construction around 220/235 ms before the ranking optimization. The old sort comparator repeatedly normalized each turn; the final code scores each turn once. Valid assertions were preserved. See [core evidence](core-evidence.md) for the method and exact commands.

## STT gate

[docs/stt-gate.md](stt-gate.md) is the detailed candidate/source/methodology ledger. All five required candidate families were exercised against the same initial licensed natural AMI audio; TDT and whisper.cpp advanced to longer calibration and shared-process dual tests. The natural corpus has 25 min with 20 min calibration and 5 min held-out. It is one technical meeting, not a representative population.

| Candidate | 20 min calibration WER | Dual processing RTF (two sources / one source timeline) | Aligned first-correct-word p50 / p95 |
| --- | ---: | ---: | ---: |
| FluidAudio TDT v3 default variant | 29.66% | 0.550 | 383.7 / 3,082.1 ms |
| whisper.cpp base.en | 30.93% | 0.390 | 303 / 1,559 ms |

Both models failed the initial 900 ms partial p95 objective under this reference-alignment proxy. Matching coverage was 82.98% / 79.42%; errors/repeated words limit alignment. These numbers include source-time cadence/lookahead/correction delay; dispatch time is not substituted for speech latency.

The shared-process 20 min workloads had no skipped input and bounded scheduling delay (TDT 17.9 ms, cpp 11.4 ms). TDT recorded an RSS peak of 180.7 MB, a physical-footprint peak of 82.6 MB and a neural-allocation peak of 490.5 MB; cpp recorded an RSS peak of 636.5 MB and a physical-footprint peak of 748.9 MB. These categories overlap and must not be added together. Neural allocation was observed; actual ANE/GPU utilization and energy in joules are unmeasured. `powermetrics` requires unavailable elevated privileges.

The subsequent corpus with distinct audio for each source exposed quiet remote speech lost by the initial VAD floor. Calibration lowered the remote RMS floor from 0.004 to 0.001 while retaining the microphone threshold at 0.004. Pure silence still produces no inference calls. The frozen held-out decision selected TDT: remote WER 23.38% versus 29.19% for whisper.cpp, with weighted scores 0.8990/0.9024 inside the declared 0.02 tie band; accuracy and footprint determined the choice. The remote sample contains 894 words, three technical terms and only one recognized question. That question finalized 3.360 seconds after its annotated end (cpp 3.268 seconds): both missed the initial 1.2-second objective because another participant continued speaking inside the same system source. The local held-out reference contains only 28 words and cannot establish general microphone accuracy.

Five supplemental system-voice framework fixtures produced TDT WER 25.27% and exact identifier recall 37.5%; these synthetic results were not used to rank human-speech accuracy. Initial and failed runs are retained. See the [selection](../Benchmarks/STT/results/backend-selection.json), [held-out summary](../Benchmarks/STT/results/paired-heldout-summary.json) and [synthetic regression](../Benchmarks/STT/results/synthetic-regression-summary.json).

## Integration and platform timing

- Real model installation through the app verified 21 files / 483,105,645 bytes. The Core ML load/silence sanity check passed inside the proper app bundle.
- Actual bundled idle SIGTERM graceful termination: 60.08 ms in `Benchmarks/results/app-idle-termination.json`. Native capture/decoder teardown is a separate measurement.
- The first 60 s paced two-source integration smoke **failed no-audio-loss**: 40 ms lost through ingress lock contention. Its [original result](../Benchmarks/results/integrated-soak-60s-before-ingress-fix.json) is preserved. After replacing the try-lock ingress with a preallocated SPSC queue, the [60 s rerun](../Benchmarks/results/integrated-soak-60s.json) passed: zero drops/gaps in both sources, 25 retained segments, at most 80 ms observed queue, 16.85 ms teardown, and zero owned tasks afterward. RSS at the 30 s warm reference was 635.11 MB and 639.03 MB before stop (+3.92 MB). This run predates the UI-host mode and is not four-hour evidence.
- The [actual native microphone smoke](../Benchmarks/results/native-microphone-smoke.json) received 6,564 native 48 kHz frames and produced ten retained segments using the selected real model, with zero observed drops. Stop took 28 ms and cleared the transcript. The last observed RTF was 0.271, local processing delay 52 ms and finalization delay 524 ms; these single observations are not p50/p95 or accuracy estimates. The artifact identifies the exact earlier Release binary; subsequent presentation/logging changes require separate final-bundle UI evidence.
- The [passive overlay check](../Benchmarks/results/overlay-passive-focus.json) delivered 100 fixture updates through the production NSPanel without activating the test process or changing the frontmost application. It does not cover a live endpoint, Spaces/fullscreen or meeting receiver capture.

- No real Grok credentials/registered OAuth client are configured. Text/vision first-delta/useful-answer timing, provider token/cache/cost usage and internet p95 are **unmeasured**.

## Completed four-hour paced integration soak

The [raw result](../Benchmarks/results/integrated-soak-14400s.json) and [run/audit metadata](../Benchmarks/results/integrated-soak-14400s-run.json) bind the immutable packaged source, test binary, corpus manifests and complete log. The original process completed normally; four selected tests in two suites passed in 14,401.149 seconds. The raw result SHA-256 is `2346be8a0d9769b573a01a08a0e03e6c2e1954ab8db386daaf7069d7cfddcbdd`.

| Measurement | Observed result | Original limit / interpretation |
| --- | ---: | --- |
| Active processing duration | 14,400.000220 s | Full four hours, independently checked beyond the pass flag |
| PCM offered, each source | 14,400.06 s; 720,003 frames; 230,400,960 samples | Each 1,500 s licensed source repeats 9.60004 times |
| Dropped audio / retained gaps | 0 / 0 for both sources | No normal-workload audio loss |
| Maximum observed ingress queue, local / remote | 0.14 / 0.24 s | 2 s per-source ingress cap; sampled observations |
| Maximum retained transcript | 167 segments / 9,736 UTF-8 bytes | 2,000 segments / 2 MiB |
| RSS at 600.0019 s warm reference | 658.516 MiB | Warm baseline includes this scenario's resident assets and views |
| RSS immediately before stop | 669.906 MiB | Growth is measured before cleanup |
| Additional retained RSS | **11.391 MiB / 1.730%** | **128 MiB** allowance: max(128 MiB, 5% of warm RSS) |
| Sampled RSS peak | **670.641 MiB** | 4 GiB objective; samples do not establish an instantaneous absolute peak |
| Coordinator / UI cleanup | 55.959 / 13.247 ms | **69.206 ms total**, below 2 s |
| Owned tasks / provider jobs after stop | **0 / 0** | Two immutable model caches intentionally remain resident |
| Recorded provider requests / completions | 239 / 239 | 191 foreground answers observed; no live provider quality/latency claim |
| Memory / thermal samples | 481, approximately every 30 s; all nominal | Full monotonic timeline retained; host was not otherwise idle |

The workload is **sparse local inference alongside sustained remote inference**. Local decoded-window coverage was 664.84 s (4.62% of offered PCM), remote 12,837.96 s (89.15%). `SourcePipeline.analysisSeconds` accumulates newly covered VAD-window time after successful inference, including padding/silence. It is not ground-truth speech duration, all offered audio, or a repeated-prefix work count. Source floors differ (0.004 local, 0.001 remote). Processing time was 132.582 s local and 2,974.082 s remote; processing/offered-audio RTF was 0.00921/0.20653, a combined 0.21574 against one source timeline. This does not establish four hours of dense simultaneous speech or quiet-microphone recognition accuracy.

The hidden production views received 171,232 state updates and 1,260 answer updates, performed 15,671 layouts and retained two native text views (maximum 200 text bytes). Cleanup removed the temporary store; no credential/token-store access or preference file was observed. No window was shown or made key/main. This measures retention in a test process, not visible long-answer rendering, a proper app-bundle session, actual microphones/ScreenCaptureKit, or a meeting receiver. The recorded provider had **zero cancellations**, so provider cancellation relies on separate focused regressions, not this soak. The last monitor was five frames (100 ms) behind each feeder; session stop intentionally releases queued tail audio, and complete tail transcription is not claimed.

OAuth fixture diagnosis/regression builds and the [clean-checkout build intervals](../Benchmarks/results/clean-checkout-verification.json) overlapped the run; no other model jobs ran. Power/thermal and overlap context are preserved rather than presenting this as an isolated laboratory run. The passing paced soak is separate from the accelerated core replay and does not override failed STT latency objectives or blocked live integrations.

## Reproduce

```sh
./script/benchmark.sh --core
Benchmarks/STT/run.sh build
Benchmarks/STT/run.sh corpus
Benchmarks/STT/run.sh models
Benchmarks/STT/run.sh test
./script/benchmark.sh --stt-initial
./script/benchmark.sh --stt-dual 1200
./script/benchmark.sh --soak 60
FREELY_SOAK_UI=1 ./script/benchmark.sh --soak 14400
```

The soak requires cached verified models and the paired licensed corpus. It performs real paced local inference/context/generation coordination with a recorded LLM fixture. The optional UI mode hosts production SetupView and NativeAnswerView in a hidden NSWindow, retains actual coordinator updates and verifies cleanup without accessing credentials, writing preferences or activating a window. This measures view retention inside the test process; proper app-bundle usability and visible interaction are separate checks. It is opt-in and ordinary CI skips it. Raw hypothesis/audio/model assets are kept in ignored local folders; compact source/metric summaries are checked in. No synthetic provider result is counted as internet/model performance.
