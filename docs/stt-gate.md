# Local speech benchmark gate

Historical logs are preserved in the [release evidence archive](evidence-archive.md); original snapshot IDs are explained in [history](history.md).

Status: **backend selection completed; several initial latency objectives were not achieved.**

Selected: **FluidAudio 0.15.6, Parakeet TDT v3 default variant**, with system-audio energy floor **0.001** and microphone floor **0.004**. Five candidates were exercised, the strongest two completed 20-minute paced dual-decoder runs, and both completed the same source-distinct held-out replay. The frozen weighted scores were 0.8990 for TDT and 0.9024 for whisper.cpp, within the declared 0.02 qualitative tie band. TDT's lower remote held-out WER and lower measured memory determined the selection; whisper.cpp retained faster first-word delivery and cancellation. The authoritative decision is `Benchmarks/STT/results/backend-selection.json`. This is a backend decision, not a declaration that all application acceptance criteria passed.

## Environment and scope

- Apple M5 Max, 18-core CPU, 128 GiB unified memory; macOS 26.6.2 (25G83).
- Initial builds: Apple Swift 6.3.3 Command Line Tools. Full Xcode was absent from the initial environment inspection.
- Later Release rebuild: stable Xcode 26.6 (17F113), Swift 6.3.3, macOS SDK 26.5, using `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. `vtool` confirms minimum macOS 15.0 in both Swift and C++ benchmark Mach-O binaries.
- Swift harness compiles in Swift 6 language mode with a macOS 15 deployment target. Runtime execution on macOS 15 has not been performed.
- AC power, battery fully charged. Thermal state is recorded at the start/end of newer Swift runs. Other development applications were open; this is not an otherwise idle laboratory machine.
- No microphone, meeting-provider application, paid API, or user recording is involved in these STT-only tests. Real native capture is a separate verification item.

## Corpus

`Benchmarks/STT/corpus-manifest.json` pins AMI EN2001a mixed-headset audio and manual annotations 1.6.2, including downloaded sizes and SHA-256 hashes. The official AMI download page licenses the signals and transcriptions under CC BY 4.0. Attribution: AMI Consortium, University of Edinburgh and partner institutions.

The fixture contains 25 minutes of naturally recorded technical conversation: original silence, interruptions, noise, crosstalk, disfluencies, and questions remain in the signal. First 20 minutes are calibration; next five minutes are held out. Fixed 15-second boundaries are identical across candidates and can truncate words. References order manually annotated words by their original start time, then channel; concurrent speakers therefore produce interleaved references that a single decoder may not reproduce.

This is one meeting, not a representative population. Broader accents and modern framework vocabulary still require additional human recordings. Supplemental system-voice framework fixtures are kept separate from the natural accuracy/ranking data. Generated PCM and upstream audio remain outside version control in `Benchmarks/STT/.cache/`.

WER normalization: lowercase ASCII alphanumeric words, preserve internal apostrophes, split punctuation/hyphens; retain fillers/repetitions; no number expansion. WER is total insertion/deletion/substitution distance divided by reference words. Technical metric version 2 preserves identifier case but canonicalizes AMI acronym spellings (`X_M_L_` / `X. M. L.` → `XML`). Question-tail matching additionally treats `off-line`/`offline` and `on-line`/`online` alike and keeps 20 prior words across empty segments. These annotation/measurement corrections were made before held-out scoring; raw hypotheses and global WER normalization were unchanged. A question tail is a lexical proxy, not proof of semantic correctness.

## Candidate examination

| Candidate | Version | Classification | Native distribution and ownership |
|---|---|---|---|
| FluidAudio Parakeet TDT v3 default variant | FluidAudio 0.15.6 | Bounded sliding-window re-inference | Swift/Core ML; separate `AsrManager` and fresh `TdtDecoderState` for each re-inferred window/source. Native integration is feasible. |
| FluidAudio Parakeet EOU 320 ms | FluidAudio 0.15.6 | Stateful streaming with cached encoder/RNNT state | Swift/Core ML; independent manager per source. Accumulated tokens require bounded finish/reset cycles. English model, distinct weights/license from TDT v3. |
| Parakeet MLX | parakeet-mlx 0.5.2, MLX 0.32.2 | Stateful cached streaming with draft re-inference | Actual upstream `transcribe_stream` exercised. Python reference is not a shippable native adapter. Shipping would need a new runtime port; rejected for v1 distribution. |
| WhisperKit | 1.1.0 | Bounded sliding-window re-inference in this adapter | Native Swift/Core ML. Upstream convenience `AudioStreamTranscriber` owns microphone recording and an accumulating buffer, so the gate feeds native `transcribe(audioArray:)` with bounded arrays. |
| whisper.cpp | 1.9.3 | Bounded sliding-window re-inference | Native C library, embedded Metal source, no demo/server runtime. Separate native contexts per source. |

The MLX test uses actual `model.transcribe_stream(context_size=(64, 8), depth=1)`, `add_audio`, `result`, `finalized_tokens`, and `draft_tokens`. Upstream defaults `(256,256)` would retain a much larger right-context region; `drop_size = right_context * depth`. Encoder frame timing is 80 ms for these model settings, giving 640 ms of draft/right context in this evaluation. Its `finalized_tokens` list grows and entering a stream mutates the model's attention mode; concurrent contexts must not be assumed safe on one shared model. The reference has no explicit audio-tail finalize operation, so final evaluated text includes draft tokens.

## Initial comparison and calibration

All initial candidates received the same first 60 seconds, 15-second bounded windows, and one-second update cadence. EOU and MLX received incremental chunks; TDT and Whisper received the available window prefix. The following are real local measurements, not upstream advertised numbers:

| Candidate | Initial WER | Initial processing RTF | 20-minute calibration WER | 20-minute processing RTF |
|---|---:|---:|---:|---:|
| Fluid TDT v3 default variant | 26.39% | 0.070 | 29.66% | 0.070 |
| whisper.cpp base.en | 40.28% | 0.034 | 30.93% | 0.038 |
| WhisperKit base.en, default decode options | 43.75% | 0.185 | Not run | Not run |
| Fluid EOU 320 ms | 46.53% | 0.014 | Not run | Not run |
| MLX Parakeet `(64,8)` | 61.81% | 0.064 | Not run | Not run |

The native strongest two were TDT and whisper.cpp. Full fixed-window calibration contains 4,097 reference words. Initial runs include downloads/compilation in reported load time and occasionally overlap other preparation work; processing RTF excludes model loading. Load measurements must be read as cold/download or warm according to their individual run.

An initial WhisperKit experiment with `withoutTimestamps: true` and zero fallback retries produced empty results after the first fixture (93.06% WER). Rerunning with native default decoding options restored transcription. The failed experiment is retained and is not the candidate's ranking result.

Dispatch duration is not speech latency. TDT's calibration dispatch p50/p95 is approximately 69/98 ms, but that excludes cadence, acoustic lookahead, and late revisions. The initial one-second cadence cannot establish the 400 ms partial objective.

First TDT load was 122.35 seconds including the network download and initial model preparation; the later cached calibration load was 126.8 ms. whisper.cpp's initial local model/Metal preparation was 6.39 seconds and its warm calibration load was 107.5 ms. Pure cold local model load isolated from both downloading and system compilation caches was not established by deleting machine-wide caches. Model metadata declares macOS 14.0 availability for all four TDT components; runtime validation here remains macOS 26.6.2 only.

## Paced latency and memory protocol

`selection-criteria.json` was frozen before held-out evaluation. Native deployment, independent decoder state, a maximum 15-second analysis window, bounded backlog, and the 4 GiB memory objective are required. The specification's initial speech latency targets remain unchanged; a failed objective is reported as failed.

The fixed-window stress replay ran both independent decoders **inside one process** at a 320 ms cadence, with a real monotonic audio clock. Each source received the same licensed audio concurrently to double processing load. This proves a two-decoder workload, not live capture or an independent-speaker recording. A later endpoint/held-out test uses distinct recorded sources. The harness records offered source time, observed output time, inference duration, backlog, and source identity. Each worker awaits its current inference and tracks overdue source time.

Reference-aligned first-correct-word latency uses AMI manual word-end timestamps and matching blocks of at least two normalized words from each partial hypothesis. It subtracts the represented word's original audio time from actual paced emission time, including cadence and processing. Coverage is reported because recognition errors and ambiguous words cannot all be timed reliably. Repeated words can create ambiguous alignments. Stable-correct-word latency records the last transition to a word sequence that remains matched through the current window. It is not an application utterance-finalization metric.

The completed 20-minute TDT replay produced 1,200 seconds per source and 7,520 partial updates. Every scheduled input chunk was processed; maximum overdue audio was 17.9 ms. Summed processing time divided by one source's timeline was 0.550, below the frozen 0.8 dual-workload bound. First-correct-word p50 was **383.7 ms** and p95 **3,082.1 ms**, at 82.98% matched-word coverage. The p50 meets the initial objective; the p95 fails it. Stable-correct-word p50/p95 was 675/10,645 ms, which is not an application utterance-finalization result. Neither dispatch timing nor a fast average RTF is used to claim that the latency gate passed.

whisper.cpp completed the same 1,200 seconds per source and 7,520 updates. Its summed dual processing RTF was 0.390, maximum overdue audio 11.4 ms, and aligned first-correct-word p50/p95 **303/1,559 ms**, at 79.42% coverage. Its p95 also exceeded the initial 900 ms objective. Source timestamps, not dispatch timestamps, anchor these estimates; matching ambiguity and different coverage limit comparisons.

`ps` sampled RSS and CPU each second. `footprint` separately measured physical/neural allocation. Completed TDT shared-process observations: RSS peak 180.7 MB; warm/final median RSS 171.5/177.8 MB; physical peak 82.6 MB; neural peak 490.5 MB. CPU averaged 50.2% in `ps` process accounting (100% represents one fully occupied CPU core). Both source start/end thermal states were nominal. Memory categories are not blindly summed. Neural allocation is observed; per-engine ANE execution/utilization and joules are unmeasured. `powermetrics` refused sampling without superuser privilege. No four-hour integrated memory or thermal conclusion follows from this run.

whisper.cpp RSS peaked at 636.5 MB, with warm/final medians 528.2/528.7 MB and physical footprint peak 748.9 MB. Its mean process CPU was 14.5%. The selection rubric's physical-plus-neural accounting formula is a ranking proxy, not exact total resident application RAM; the original RSS and footprint categories remain separately recorded.

The initial two-process pilot was stopped after roughly one minute when shared-process ownership was requested. It is incomplete and not the final gate.

`prepare_dual_corpus.py` built genuinely distinct synchronous AMI sources: headset0/annotationA as `localUser`, and a normalized mix of actual headsets1–4/annotationsB–E as `systemAudio`. Their original clock and natural overlap are preserved. Source roles are simulated; neither is live application capture. `dual-corpus-manifest.json` records source hashes and the annotation channel mapping. Audible bleed can produce words absent from the target-headset annotation, particularly in the sparse local track.

## Causal endpoint calibration and held-out decision

Both native drivers use the same C VAD implementation, fed continuously in 20 ms frames. It matches the application's energy policy: 200 ms preroll, 450 ms ending silence (quantized to frame boundaries), 15-second maximum window, 160 ms minimum voiced audio, 320 ms minimum analysis input, and 320 ms inference cadence. The adaptive threshold is `max(sourceFloor, min(0.012, noiseRMS * 3))`. Inference begins before utterance completion; no complete utterance is recorded before transcription starts.

Calibration exposed a real failure in the original 0.004 system floor: only 70.44% of remote annotated word starts reached decodable windows. TDT/whisper.cpp remote WER rose to 48.41%/46.52% with that policy. The waveform was kept unchanged. Lowering the floor to 0.001 recovered 99.30% of remote word starts; 0.0005 recovered 99.84% but caused more noise activity. Five-minute calibration WER with 0.001 was 21.71% TDT and 22.56% whisper.cpp; at 0.0005 it was 19.18% and 22.80%. The final 0.001 system / 0.004 microphone policy was frozen at **2026-09-07 03:47:42 UTC**, before held-out runs, in `endpoint-selection-criteria.json`.

The source-distinct five-minute held-out replay used two independently constructed decoders in one process for each engine, preserving the actual source clock. Whole-source WER includes words omitted by VAD. The scored remote reference contains **894 words**, only **three technical-term occurrences**, and **two question-mark annotations**; one is a lexical question, the other “Hmm”.

| Held-out system audio | TDT default variant | whisper.cpp base.en |
|---|---:|---:|
| WER | **23.38%** | 29.19% |
| Case-sensitive technical recall / F1 | 66.67% / 0.80 | 66.67% / 0.80 |
| Recognized question tails | 1 of 2 | 1 of 2 |
| Recognized question end → finalized transcript | **3.360 s (n=1)** | **3.268 s (n=1)** |
| Nonempty silence-end finalization, reference-aligned p50/p95 | 103 / 1,037 ms | 361 / 1,473 ms |
| Processing RTF | 0.202 | 0.100 |
| Maximum overdue audio | 70.3 ms | 41.3 ms |

The local held-out track contains just **28 words**: TDT WER 50.00%, whisper.cpp 35.71%. This small result is reported rather than hidden, and does not establish broad microphone accuracy.

The recognized question ended at source time 190.72 s; another remote participant started speaking at 191.02 s. Source-wide VAD therefore delayed finalization until approximately 194 s. Both engines **missed the initial 1.2-second stable-finalization objective on this question**. With one recognized sample, p50/p95 equal that observation and cannot estimate a population p95. Backend speed alone does not remove this delay. The finalization estimate also depends on imperfect word annotations; empty finals and negative reference delays are excluded, so the utterance table is conditional rather than a universal latency guarantee.

The frozen ranking weights were WER 35%, technical F1 loss 15%, question-tail misses 15%, question finalization delay 25%, memory proxy 8%, and active cancellation 2%, after native/boundedness gates. Scores **0.8990 / 0.9024** fell within the frozen 0.02 qualitative tie band. TDT was selected for lower remote held-out WER and footprint, supported by its other natural-corpus comparisons. whisper.cpp's faster partials and cancellation remain documented advantages. No acceptance threshold was raised to turn a failed objective into a pass.

## Silence, noise, and supplemental speech

Five seeded 30-second numerical controls cover digital silence and stepped white-noise RMS levels 0.0003, 0.00075, 0.002, and 0.01. Pure digital silence and quiet 0.0003 noise produced zero VAD inference calls. At the selected system floor, TDT produced six transient nonempty noise hypotheses but **zero nonempty final transcripts**; these were false speech hypotheses. Lowering the floor to 0.0005 added 89 inference calls and included a transient “What?”, supporting the more conservative 0.001 choice.

whisper.cpp returned explicit non-speech annotations such as `[silence]`, `[BLANK_AUDIO]`, and `[SOUND]` on activated noise. These are not verified spoken meeting words and would need appropriate adapter handling if that backend were selected. Noise is not claimed to be perfectly rejected. `noise-summary.json`, `noise-fixture-manifest.json`, and `vad-calibration-coverage.json` retain the evidence and CPU/inference-call tradeoff.

After the natural gate was frozen and completed, five framework-name fixtures were generated from project-authored English text with the installed macOS Samantha voice and actually transcribed through both native backends. They total **34.80 seconds / 91 reference words** and cover Kotlin/StateFlow/SharedFlow/Compose/Gradle/REST and macOS APIs, a spoken negation correction, and follow-ups. TDT synthetic WER was **25.27%**, exact case-sensitive identifier recall **37.5%** (6/16); whisper.cpp was **20.88% / 43.75%** (7/16). Both retained the spoken “not”. Many identifiers became spaced/lowercase phrases; this is a limitation, not a successful identifier-fidelity claim.

These results did not change backend selection. Generated speech cannot establish human framework-name accuracy, and speaking a correction does not guarantee a late ASR revision or correct generation supersession. `synthetic-fixture-manifest.json` records text, installed voice/provenance and output hashes; `results/synthetic-regression-summary.json` retains per-fixture hypotheses. Generated audio remains ignored in `.cache/`. There is no human recording or redistributed Apple voice asset in the fixture source.

## Production integration constraints

The SDK `.int8` selector loads the default `Encoder.mlmodelc`, whose actual metadata reports mixed Float16 and 6-bit palettized storage. The preprocessor is Int8, while decoder/joint are Float16; this is not an all-INT8 weight bundle.

The pinned TDT manifest contains **21 files, 483,105,645 bytes**, HF revision `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`. All downloaded files were individually SHA-256 checked. Model weight license: CC BY 4.0; FluidAudio code: Apache 2.0. EOU's weight license is NVIDIA Open Model License and must not inherit the TDT notice.

Load verified files directly through native Core ML and initialize `AsrModels(encoder:preprocessor:decoder:joint:configuration:vocabulary:version:)` to avoid SDK download/recovery paths. Use `Preprocessor.mlmodelc` on `.cpuOnly`; `Encoder.mlmodelc`, `Decoder.mlmodelc`, and `JointDecisionv3.mlmodelc` on `.cpuAndNeuralEngine`. The SDK's configuration enables `allowLowPrecisionAccumulationOnGPU`; no optimization hints are applied. `parakeet_vocab.json` maps stringified token IDs to strings; pass `.v3` and no CTC head.

For a full bounded-window re-inference, construct a fresh `TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)` and call `manager.transcribe(samples, decoderState: &state)`. Reusing a continuation decoder state while refeeding the same audio prefix is incorrect. Managers/decoder state remain source-owned. Do not adopt `SlidingWindowAsrManager` unchanged: its input `AsyncStream` is unbounded, and its accumulated transcript/tokens grow over a session.

The TDT pipeline and inner decoder loops check task cancellation. A Core ML prediction already in progress may finish before cancellation is observed. Production must invalidate epoch/generation identities before cancellation, await worker termination, and discard fenced late results. Nine actual active 15-second-window requests were cancelled at 5/20/50 ms delays: cancellation-to-termination p50/p95 was 17.6/39.6 ms, with all nine throwing cancellation and no normal result returned afterward. This is decoder termination evidence, not native capture stop or full session teardown. Direct local loading was also exercised with real 15-second audio for TDT, EOU, and WhisperKit after replacing SDK downloading with pinned cached model paths.

A matched dense 15-second cancellation fixture subsequently measured TDT p95 **40.1 ms** and whisper.cpp p95 **9.8 ms**, with nine active requests per engine and no normal result returned after active cancellation. whisper.cpp uses its native `abort_callback` with an atomic flag. Cleanup follows inference termination; it is not invoked concurrently to force a suspended decoder to stop.

## Reproduction and evidence

```sh
Benchmarks/STT/run.sh build
Benchmarks/STT/run.sh corpus
Benchmarks/STT/run.sh paired
Benchmarks/STT/run.sh models
Benchmarks/STT/run.sh test
Benchmarks/STT/run.sh initial
Benchmarks/STT/run.sh dual 1200
STT_GATE_SYSTEM_RMS_FLOOR=.004 STT_GATE_RUN_SUFFIX=baseline Benchmarks/STT/endpoint_run.sh calibration
STT_GATE_RUN_SUFFIX=frozen Benchmarks/STT/endpoint_run.sh heldout
Benchmarks/STT/run.sh cancel
Benchmarks/STT/run.sh synthetic-test
```

Full JSONL hypotheses/resource timelines are local evidence under `Benchmarks/STT/results/` and ignored by Git; compact summaries and provenance are versioned. `results/raw-evidence-index.json` records SHA-256 hashes and sizes for the canonical raw streams. Authoritative final artifacts are `results/backend-selection.json`, `results/paired-heldout-summary.json`, `results/candidate-cancellation-summary.json`, and each candidate's `*-dual-*summary.json` / `*-dual-aligned-latency.json`. `endpoint_analyze.py` and `select_backend.py` reproduce the endpoint summary and frozen score. Initial/calibration summaries, manifests, and `candidate-versions.json` preserve the earlier comparison. `Package.resolved` and `python-requirements.lock` pin dependencies. Eight fast/native measurement tests cover edit distance, normalization, source completion, aligned latency, preroll/endpoints, and rejection of unconsumed overflow.

Application-wide acceptance remains in the main verification ledger: these STT-only results do not establish a four-hour integrated soak, real simultaneous native capture, provider latency/answer usefulness, broad human accent/framework-name accuracy, or behavior on macOS 15 hardware. Energy counters were unavailable. Completed held-out/dual-decoder measurements are not listed as pending; failed initial latency objectives remain failed.

## Source ledger

All accessed 2026-09-07; code APIs also read from pinned upstream source checkouts.

| Source | Decision/evidence | Remaining uncertainty |
|---|---|---|
| [FluidAudio 0.15.6](https://github.com/FluidInference/FluidAudio/tree/v0.15.6) | Swift 6 package, macOS 14+, native Core ML APIs and cancellation checks | Runtime macOS 15 not exercised |
| [TDT model card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/7dd20fe6b1797d35f5e3307e8b1732d9a178edfe) | Pinned files, CC BY 4.0, mono 16 kHz adapter | English tested here; other languages not exposed |
| [EOU model card](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml/tree/40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355) | Distinct English streaming weights and NVIDIA license | No production selection or long EOU soak |
| [Parakeet MLX source](https://github.com/senstella/parakeet-mlx/tree/b78130e3aa1788e89707ec164adbea8865316aaf) | Real cached streaming/draft API; Python evaluation only | No maintained native adapter verified |
| [WhisperKit 1.1.0](https://github.com/argmaxinc/argmax-oss-swift/tree/v1.1.0) | Native bounded audio-array decoding; package macOS 13+ | Continuous app integration not exercised |
| [whisper.cpp 1.9.3](https://github.com/ggml-org/whisper.cpp/tree/v1.9.3) | Native library, Metal backend, independent contexts | Distribution integration remains an alternative |
| [AMI download/license](https://groups.inf.ed.ac.uk/ami/download/) | Real meeting corpus and manual annotations, CC BY 4.0 | One-meeting population limits |
