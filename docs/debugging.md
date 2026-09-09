# Debugging Freely

Open **Actions → Diagnostics** or use Command–K to search for Diagnostics. Overview, Events, Timings and Environment live inside the same panel. Expand enlarges that panel. The Codex **Diagnostics** action builds and opens this page with detailed events enabled.

```bash
./script/build_and_run.sh --diagnostics  # build, launch, open console, enable debug detail
./script/build_and_run.sh --telemetry    # same, plus a live unified-log stream
./script/build_and_run.sh --debug        # debug-only signature, launch under LLDB
./script/diagnose.sh                    # save the last 15 minutes of Freely unified logs
./script/diagnose.sh --sample           # also take a five-second stack sample of a running app
```

The run script ends any existing Freely process before rebuilding. End a live meeting deliberately before running it. `diagnose.sh` leaves the app running. Captures go into unique, private directories under `dist/diagnostics/`; a failed capture returns a nonzero exit code.

## Reproduce and attach useful evidence

1. Open **Events**, enable **Debug detail** when investigating decoding, and click **Add marker** immediately before reproducing the problem.
2. Search by category, severity, event/field text, or full session/request UUID. Newest events appear first. Select a row for complete IDs and fields. Correlation IDs are opaque app-generated identifiers; they are not provider credentials or provider response IDs.
3. **Pause events** freezes the event/timing/environment snapshot while recording continues. The health page continues reflecting live application state. Clear only resets the in-memory events, counts, and timing samples. macOS logs and previously exported files remain.
4. **Copy report** or **Export JSON…** captures every retained event and the application state at the last console refresh, independent of the active filters. The save dialog captures a fixed snapshot before opening; it does not silently export a later state. Reports include their timestamp, run ID, app version, build configuration, Git revision, and whether the source tree was modified when the bundle was built.
5. Include the action you took, what you expected, and the selected session/request ID. A report by itself does not establish speech accuracy, successful permission authorization, or provider entitlement.

The console keeps **2,000 events**. Its footer reports eviction and omitted debug events. This is a bounded recent history, not a complete meeting recording. The recorder never stores transcripts, prompts, answers, images, credentials, names of devices/applications/windows, or file paths. User-facing error text is visible locally in the health page but is excluded from reports. Do not add raw error descriptions, process output, URLs, request bodies or headers to event fields.

## Read the pipeline

| Evidence | What it tells you |
| --- | --- |
| `app.launched`, `app.ready`, `app.stopping`, `app.stopped` | Startup and graceful termination reached those boundaries. `app.ready` reports model/connection readiness separately. |
| `session.started`, `session.ready`, `session.stopping`, `session.stopped` | One session's lifetime; ready carries the number of running sources. Zero sources is not successful capture. |
| `audio.source_state`, `audio.source_failed`, `audio.gap`, `audio.source_summary` | Source transitions, classified capture failures, accepted discontinuities with cause/lost duration, and per-source totals retained after stop. Permission settings alone do not prove capture works. |
| Frames, peak, last-audio age, queue, dropped seconds | Whether the source produces data and whether processing keeps up. Audio presence is not proof of recognized speech. |
| `stt.decode_completed`, `stt.decode_failed` | Inference duration, final/partial window, and whether the recognizer returned empty text. Decode events require debug detail; timing samples do not. |
| `context.prepared`, `context.invalidated` | Selected context budget/revision and corrections that invalidate an answer. No selected text is logged. |
| `llm.generation_started`, `llm.first_visible_text`, terminal generation events | Request arbitration, first visible output, completion, interruption, cancellation or failure, correlated with the provider request. |
| `network.request_started`, `network.response_received`, `network.retry`, terminal request events | Direct API attempts, HTTP status, backoff, and classified transport errors. Provider adapters identify their transport in fixed fields. No HTTP bodies or headers are collected. |
| `auth.*`, `model.*`, `screen.*`, `overlay.*` | Authentication/install boundaries, consent changes, screenshot dimensions, and overlay visibility/interaction. |

**Timings** retains the latest **256 valid measurements per event name**. Count includes all measurements since Clear; p50/p95/max cover only the retained window. Decode timings aggregate both sources; use source-filtered debug events for individual decodes. Queue duration, real-time factor, window processing delay, and first visible text measure different stages. Unknown provider token usage is omitted, not reported as zero. No p95 service guarantee is implied.

**Environment** also shows resident memory, thermal-state code, and owned session task count. A stopped session can retain a warm speech-model cache. Owned tasks count coordinator work, not every Foundation/Core ML task. macOS screen-pixel preflight and microphone authorization are separate from actual system-audio capture success.

## Logs, crashes and hangs

Structured events use subsystem `local.freely.app` and categories matching the event prefix. Info events use Apple's notice level, warnings/errors their corresponding unified-log levels, and optional detail uses debug. macOS controls retention and may omit older or debug messages. The in-memory console does not survive process exit; export before quitting when possible.

```bash
/usr/bin/log stream --level debug --style compact \
  --predicate 'subsystem == "local.freely.app" && category == "network"'
```

`diagnose.sh` uses Python 3 to keep only structured events from the Freely process and strip macOS path/backtrace metadata. It captures Freely's subsystem, not a whole-machine log archive. A stack sample is a separate developer artifact and can contain local binary/source paths; inspect it before sharing. macOS crash reports are available in Console under Crash Reports, or in `~/Library/Logs/DiagnosticReports/` for the Freely process. Crash reports may also contain machine/path information and are not included automatically in the safe JSON export.

Use `--debug` for breakpoints and backtraces. At the LLDB prompt:

```text
process interrupt
thread backtrace all
breakpoint set --name swift_willThrow
continue
```

The Swift error breakpoint is intentionally noisy; use it only when tracing an unexplained throw. A fatal signal cannot reliably flush a Swift recorder, and an unresponsive MainActor cannot update a SwiftUI console. Use macOS crash reports or `diagnose.sh --sample` in those cases. This setup does not install crash handlers or upload telemetry.

Only `--debug` adds `com.apple.security.get-task-allow` to a temporary copy of the entitlements for that local debug bundle. Ordinary and release builds use the original entitlements. Release mode rejects `--debug`; signing policy is not weakened globally. A normal rebuild replaces the local debugger-enabled bundle.

## Add instrumentation

Use the closed `DiagnosticName`, `DiagnosticField` and `DiagnosticValue` APIs in `FreelyLog.swift`. Values accept authored literals, numbers, booleans, known source enums and centrally classified errors. Scopes accept UUIDs. Arbitrary dynamic strings cannot be passed as values.

```swift
FreelyLog.record(.sourceFailed, level: .error,
    scope: .init(session: sessionID, source: source),
    fields: [.failure: .failure(error)])
```

Record control transitions and operation results, not every UI mutation or stream token. Do not invoke the recorder from a real-time audio callback. Keep correlation explicit across asynchronous ownership boundaries. New error types should receive an exhaustive classifier that drops associated private payloads.

The recorder uses a lock-protected fixed ring; it does no disk/network I/O and creates no tasks. Reports project only allowlisted application state. The console refreshes twice per second while live. A paused console does not stop capture, inference, or logging.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --arch arm64 --no-parallel --filter DiagnosticTests
```

The diagnostics tests exercise concurrent producers, retention accounting, filtering, bounded timing samples, error/report privacy, and generation-to-provider correlation. They use deterministic inputs and fixture providers, without sending meeting content or paid requests.
