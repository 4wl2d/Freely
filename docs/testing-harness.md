# Background test harness

Use the short background checks while continuing to work on the Mac:

```sh
./script/harness.py start
./script/harness.py status
./script/harness.py stop
```

`start` returns immediately. **Background tests** and **Stop tests** are also available in the Codex project actions. `./script/test.sh` without arguments runs the same safe profile synchronously.

The default profile runs the core tests, builds the native test target and runs the application regressions. It:

- shows no windows, changes no focus and launches no fixture app;
- uses in-memory frames for presentation tests, without ScreenCaptureKit or capture permissions;
- preserves the running Freely app and its meeting state;
- clears inherited `FREELY_*` opt-in flags so an old shell environment cannot enable visual or long-running tests;
- runs at nice +10, limits compiler jobs to two and runs tests serially;
- enforces phase deadlines and stops only its owned process tree, including SwiftPM helpers with separate process groups;
- writes status, phase durations and logs under `.cache/harness/<run>/`.

Native text layout still uses an unshown AppKit host; the presentation coordinator's memory output creates no output window. Tests assert that no visible window was added and that the test process did not become the foreground application. Users switching between their own applications do not invalidate that check.

The presentation capture adapter is injectable. The fast fixture exercises production composition, visibility revisions, source restart, late-frame rejection and cleanup using immutable pixels. It does **not** establish real ScreenCaptureKit or receiver behavior.

For a synchronous or Release run:

```sh
./script/harness.py run
./script/harness.py start --release
```

An optional short local-STT check uses cached models, the prepared PCM corpus, recorded answers and synthetic video:

```sh
./script/harness.py start --stt-seconds 10
```

This accepts 10–60 seconds and still opens no windows. Long soaks are not part of the normal harness. If the local speech model or `.cache/redesign-soak-corpus` is missing, this explicit profile fails rather than downloading models, opening permissions or starting capture.

## Visual checks are explicit

```sh
./script/harness.py visual
```

This foreground opt-in runs the native output readback check. It requires screen-capture authorization and the separately opened public CaptureFixture source. Its output is a normal 640 × 360 preview with a title bar and close controls, not the large borderless click-through output used by the application. The stop command works from another terminal and terminates the owned test process tree, including its windows.

Do not use visual checks during normal parallel desktop work. The default `start` profile never enables them. Full screenshot galleries and receiver checks remain separate manual acceptance work.

The interrupted 30-minute run is not a pass; it was stopped at the user's request because its output window interfered with other work. The new background checks replace that loop for routine development.

Verified locally: **49 core tests and 185 application tests passed** (15 visual/long-run opt-in skips), in **13.2 seconds including the incremental build**. Cancellation stopped the owned SwiftPM tree and left the running Freely process intact. [Evidence](../Benchmarks/results/harness-verification.json). Release and real capture were not repeated after extracting the headless adapter.
