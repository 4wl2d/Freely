# Privacy, permissions and capture coverage

## Freely subscription transport

The default subscription connection invokes official Grok Build with a private temporary workspace, tools/rules/hooks/memory disabled, and conversation writeback disabled. Its auth file remains owned by Grok Build. Selected text and any explicitly enabled image pass through that client's subscription route. Temporary request and CLI-history files are deleted after normal completion or cancellation; force quits can interrupt cleanup. Provider retention and subscription billing follow the account's policies. API-key requests continue to use the direct Responses route. See [connection details](oauth-evidence.md).


Freely processes microphone and meeting audio locally. It sends only selected, bounded text context and explicitly enabled images for Grok inference. Screen context starts **Off** for each session. Freely does not create a permanent meeting recording or transcript archive. The Grok Build path creates temporary request/client files with the cleanup behavior described above.

## Data flow

| Data | Processing and destination | Lifetime or persistence |
| --- | --- | --- |
| Microphone PCM | AVFoundation captures the selected input; native conversion and local Core ML speech recognition process owned buffers. | Bounded memory only. Production code does not write or upload microphone audio. |
| Meeting/application PCM | ScreenCaptureKit captures the explicitly selected application or the separate all-system-audio scope. | Bounded memory only. It is not uploaded to Grok or saved as a recording. |
| Transcript, turns and questions | Local reconciliation and context selection preserve source/revision provenance. | Volatile, bounded session state; cleared on session end. Compacted or evicted text is not a complete meeting archive. |
| Selected text for an answer | Trusted instructions, the active question and necessary antecedents, selected profile/session context, relevant conversation, summaries and clearly identified prior AI suggestions form a bounded inference request. | Sent to the configured xAI inference endpoint. Direct API requests use `store:false`; Grok Build uses its subscription route. Provider retention is separate for both. |
| Semantic summaries | Grok may summarize selected older conversation; the local engine validates the covered source revisions before accepting the result. | The selected summary input leaves the device. Summary state remains bounded and volatile; offline fallback is local and extractive. |
| Screen image | On-demand ScreenCaptureKit screenshot of the selected display, window or display region, prepared as SDR/sRGB PNG. | Sent only for a request allowed by current session consent and source selection. At most one latest image is retained by the current adapter; it is cleared on revocation, selection change or session end. |
| Profiles and preferences | Explicitly entered or imported profile text and nonsecret choices are stored locally. | Versioned `preferences.json` under `~/Library/Application Support/Freely`. Profile text is plaintext, not encrypted by this application. |
| Session notes and pinned facts | Included only in selected session context. | Volatile and cleared at session end; not saved in preferences. Pinning an answer does not turn it into a recording. |
| API key and optional registered OAuth token set | Native Keychain items hold the optional API key and the separate rotating OAuth access/refresh/expiry/client/scope set. | The items are configured as non-synchronizing and device-only. Token contents are absent from preferences and diagnostics. |
| Grok Build sign-in | Only the official client reads/refreshes its existing auth file. | Freely stores only an enabled-connection flag. Disconnect does not log out other Grok Build sessions. |
| Model assets | Public pinned files are downloaded from Hugging Face; HTTPS object-storage redirects are permitted and every file is size/hash verified. | Stored under `Application Support/Freely/Models`. Model downloads contain no meeting audio, transcript or screenshot payload. |
| Diagnostics | The debug console retains up to 2,000 typed events plus bounded timings, lifecycle state, and classified errors. Copy/export is explicit. | JSON reports exclude meeting content, credentials, device/window/application names, paths, and user-facing error text. macOS retains unified logs separately; raw stack/crash artifacts need review before sharing. See the [debugging guide](debugging.md). |
| Explicit transcript export | **Export excerpt** writes the currently retained text to the location chosen in the save panel, with a retained-excerpt/compaction label. | This is an explicit user-created file outside the session's volatile state. Ending the session does not delete an exported file. |

The direct API provider's [current data policy](https://docs.x.ai/developers/faq/security) describes default 30-day audit retention and a separate team-level zero-data-retention arrangement. `store:false` disables stateful response storage; it is not a blanket promise that the provider retains nothing. Account agreements and any approved subscription integration must be checked independently.

Observed speech, imported material and images are untrusted context. They cannot enable tools or change application permissions. V1 requests do not expose browsing, shell, remote MCP or computer-control tools. Generated suggestions are not represented as statements the user actually spoke.

## Capture scope and consent

Audio and visual source choices are independent. Selecting Chrome for audio means Chrome application audio, potentially including other tabs; selecting one Chrome window for a screenshot does not create browser-tab audio isolation. The all-system-audio option must be selected explicitly. If an application disappears, the app reports a source failure instead of broadening capture.

The app excludes its own audio from system capture and disables ScreenCaptureKit microphone capture because AVFoundation already owns the microphone. For audio-only sessions it registers only an audio output: no screen frames are delivered to or inspected by the application. ScreenCaptureKit still uses an OS content filter and may require capture authorization or perform internal display work; the absence of an app video-output callback does not prove otherwise.

Visual modes are **Off**, **Manual capture only**, and **Automatic for relevant questions**. Enabling a mode is a session-level decision, and a source must be selected. Source/crop/consent revisions are checked around asynchronous work and before outbound inference. Turning visual context off cancels obsolete visual work and discards retained images. Cancelling a region edit preserves the existing crop; a late result cannot apply display A's region to display B. Images are bounded to a 2,048-pixel long edge and 4 MiB, and ordinary freshness expires after about 30 seconds.

The app excludes its own windows from its own display screenshots and rejects its own windows as a visual source. This says nothing about whether another meeting or recording application captures the overlay. It does not use process hiding, security-product evasion or falsified window/process enumeration.

## macOS permissions

| Capability | Native mechanism | What a successful check proves |
| --- | --- | --- |
| Microphone | AVFoundation authorization and `NSMicrophoneUsageDescription`; the hardened-runtime app declares the audio-input entitlement. | Authorization permits an attempt. Actual received PCM and a clean stop are separate runtime evidence. |
| System/application audio | ScreenCaptureKit and the declared system-audio/screen purpose strings. macOS may present Screen & System Audio Recording controls, including an audio-only grant on supported versions. | The app picker uses running-app metadata without a recording grant. Only real audio delivery proves capture permission and source output. |
| Screen images | Separate session consent plus the OS authorization needed for ScreenCaptureKit screenshots. | `CGPreflightScreenCaptureAccess` is a screen-pixel authorization hint; it is not a universal test of audio-only permission or actual screenshot contents. |
| Global shortcuts | Carbon `RegisterEventHotKey`, with conflict detection and menu alternatives. | Registration confirms that a binding was accepted. No blanket key monitor or Accessibility permission is used. Physical keypress behavior is a separate check. |
| Profile import/export | Native open/save panels for a user-chosen file. | The app can read/write the chosen file. Text/Markdown imports preserve the original file and save a derivative in the selected profile. |
| Grok sign-in | Official Grok Build browser sign-in, or its existing grok.com session. | Connect verifies a short text request. Optional image reasoning needs its own session check. |

Only the inputs enabled for a session are started. An explicit microphone UID never changes the system-wide default device. When following the default input, a device/default-route change can stop the affected source and ask the user to resume against the new route. Permission denial and source failure remain independent, so a working source can continue.

Workspace sleep, display sleep and session-deactivation notifications request a pause, never an automatic resume. The app additionally listens for `com.apple.screenIsLocked` through the distributed notification center. Apple does not document that notification name as a stable contract; its presence in code is not proof of physical lock handling on the current OS or the deployment minimum. The physical lock/sleep matrix below remains **NOT TESTED**.

Capture errors now retain an allowlisted native error domain and numeric code. ScreenCaptureKit `-3801` is identified as denied authorization. Other failures are not automatically attributed to permission. Raw localized error bodies, unknown domain strings and private window titles are excluded from this diagnostic.

## Signing, TCC and local storage

The app is configured for direct distribution with hardened runtime, without App Sandbox or broad JIT/library-validation exceptions. A local artifact without an owner-supplied Developer ID identity is ad-hoc signed and not notarized. The permission record for an earlier binary is not proof that a changed ad-hoc binary is currently authorized. A visible entry in System Settings, a prior successful grant and a current successful capture are different pieces of evidence.

If macOS requests confirmation, complete the native prompt and quit/reopen when directed. Do not disable Gatekeeper, bypass TCC or edit its database. The current build's source-list error code should be used to distinguish an actual denial from another native failure; a signing-identity mismatch must not be asserted without evidence.

Preference directories/files use user-only filesystem permissions. These permissions are not profile encryption. Credentials use Keychain instead of those files. **Clear local data** cancels pending saves/imports and removes local settings, saved profiles and credentials, with downloaded-model deletion as a separate explicit choice. A failed local Keychain deletion is reported as a failure; successful local deletion with unconfirmed remote OAuth revocation is reported separately. Existing exports, backups and data already transmitted to a provider cannot be recalled, and no forensic-erasure guarantee is made.

## Verified local primitives

| Check | Evidence | Result and limit |
| --- | --- | --- |
| Passive native overlay updates | [`overlay-passive-focus.json`](../Benchmarks/results/overlay-passive-focus.json), macOS 26.6.2 (25G83), recorded on 2026-09-07 | **PASSED:** the production panel/controller in a test process remained visible for 100 fixture updates at 40 ms cadence, did not become key or activate itself, and retained the initially frontmost Kitty application. This was not a live Grok, fullscreen, Spaces or capture-visibility test. |
| Actual microphone repeat after typed-clock fix | [native-microphone-smoke.json](../Benchmarks/results/native-microphone-smoke.json), normally launched Release app, 2026-09-07 | **PASSED within the recorded run:** default built-in input at 48 kHz, 6,564 native frames, 10 retained segments, observed dropped duration 0, stop 28 ms and 0 retained segments. Typed CF-clock access/type validation and callback quiescence were exercised after the earlier KVO-clock failure. No raw audio/text persisted and no cloud request. System audio was explicitly disabled after -3801; this is one microphone/run, not simultaneous capture or percentile/accuracy evidence. The artifact pins its executable hash; later package bytes require their own runtime checks. |
| Paced local two-source processing smoke | [`integrated-soak-60s.json`](../Benchmarks/results/integrated-soak-60s.json) | **PASSED for its fixture boundary:** 60 seconds of real local inference/coordinator processing, zero dropped seconds for both sources and no owned jobs after stop. It used fixture capture and recorded LLM output; it did not exercise microphones, ScreenCaptureKit, subscription access or a meeting receiver. It is not a four-hour soak. |
| Four-hour local-processing retention | [raw soak](../Benchmarks/results/integrated-soak-14400s.json), [method](benchmarks.md#completed-four-hour-paced-integration-soak) | **Passed within its fixture boundary:** real local decoders, paced licensed source files, recorded LLM and hidden production views. Zero audio loss; 11.391 MiB warm-to-final RSS growth; no owned work after 69.206 ms teardown. Sparse local inference, no actual capture, no visible long-answer UI, no provider cancellation in this run. |
| Context/consent and crop fencing | [App-surface evidence](app-surface-evidence.md), [native-adapter evidence](native-adapter-evidence.md) | Deterministic tests pass. Geometry and scripted image acquisition do not establish actual multi-display screenshot contents. |

## Meeting and capture compatibility matrix

No actual meeting receiver or recording output has been examined for the combinations below. The current test host is macOS 26.6.2 (25G83); macOS 15 is the deployment minimum, not an exercised compatibility matrix. Application versions must be recorded when each test is conducted.

| Application/version | OS actually exercised for this combination | Sharing/capture mode | True window surface or cropped display established? | Receiver/recording examined? | Overlay visibility | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Google Meet / Chrome — version not recorded | Not tested | Selected-window sharing | No | No | Unknown | **NOT TESTED** |
| Google Meet / Chrome — version not recorded | Not tested | Full-display sharing | No | No | Unknown | **NOT TESTED** |
| Zoom — version not recorded | Not tested | Selected-window sharing | No | No | Unknown | **NOT TESTED** |
| Zoom — version not recorded | Not tested | Full-display sharing | No | No | Unknown | **NOT TESTED** |
| Microsoft Teams — version not recorded | Not tested | Selected-window sharing | No | No | Unknown | **NOT TESTED** |
| Microsoft Teams — version not recorded | Not tested | Full-display sharing | No | No | Unknown | **NOT TESTED** |
| Discord — version not recorded | Not tested | Selected-window sharing | No | No | Unknown | **NOT TESTED** |
| Discord — version not recorded | Not tested | Full-display sharing | No | No | Unknown | **NOT TESTED** |
| Slack calls — version not recorded | Not tested | Selected-window sharing | No | No | Unknown | **NOT TESTED** |
| Slack calls — version not recorded | Not tested | Full-display sharing | No | No | Unknown | **NOT TESTED** |
| Other recording application — not selected | Not tested | Window recording | No | No | Unknown | **NOT TESTED** |
| Other recording application — not selected | Not tested | Full-display recording | No | No | Unknown | **NOT TESTED** |

| Additional platform journey | Status |
| --- | --- |
| Fullscreen meeting application with the companion panel | **NOT TESTED** |
| Spaces transitions during a live meeting | **NOT TESTED** |
| Mixed-scale or rotated displays; display unplug/movement during capture | **NOT TESTED** |
| Physical screen lock/sleep/wake during real dual-source capture | **NOT TESTED** |
| Bluetooth route change or physical microphone unplug during a real meeting | **NOT TESTED** |
| Current final bundle capturing real microphone and selected application audio simultaneously | **NOT TESTED** |

`NSWindow.sharingType = .none`, keeping an accessory app out of the Dock, and excluding this app from its own screenshots are not evidence that an external capture hides the overlay. Verify the actual receiver's view or recording separately for window and display sharing, record the application/OS versions and capture-surface type, and use the immediate hide/show control when needed.
