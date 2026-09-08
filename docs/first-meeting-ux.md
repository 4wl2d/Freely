# Freely 0.2.0 — installation and first-meeting verification

Checked on 2026-09-08. This record distinguishes current live checks from the [original pre-rebrand evidence](archive/verification-2026-09-07.md).

## Changes exercised

- Renamed the repository, Swift targets, domain package, bundle, resources, scripts and current documentation to Freely. Legacy identifiers remain only as migration keys and in historical records.
- Replaced the ordinary subscription button's missing-registration dead end with official Grok Build sign-in and a real short subscription test. Progress, cancellation, missing-helper recovery and connection results are visible.
- Added private, temporary request workspaces; disabled client tools/imported integrations; bounded output and subprocess lifetime; awaited cancellation and cleanup. The app does not read Grok Build tokens or silently use an API key.
- Made Start/setup readiness reflect enabled audio sources and microphone permission. App selection now lists foreground-capable apps without requiring a screen-recording grant just to populate the picker.
- Recognizes a direct question after introductory speech, including the comma-separated text produced by the speech model in the test meeting.
- Added an actionable macOS screen-recording denial message. The parallel diagnostics task contributed the event console, classified failures, timing views and export/capture tools used during this check.

## Verified before final packaging

| Step | Observed result |
| --- | --- |
| Original Connect button | Reproduced: click changed neither the UI nor authentication state when the native client ID was absent. |
| Rename and migration | Freely launched, copied the existing speech model/settings, and verified the 483.1 MB model. Original data was preserved. |
| Subscription | The actual Freely Connect action reached a successful `grok-4.6` response through the user's grok.com/Grok Build sign-in. |
| Relaunch | The explicitly enabled connection was restored; capture did not restart automatically. |
| Model download | The full model was downloaded again through the UI, showing byte progress and completing hash verification. |
| System audio and STT | An isolated CaptureFixture app played synthetic English speech; Freely displayed the recognized meeting text. |
| Question detection | The initial live run exposed a missed trailing question. A regression test now recognizes the exact observed transcript and retains its introductory context. |
| Subprocess cancellation | Regression exposed buffered pipe reads delaying cancellation. Bounded POSIX reads fixed it; the cancellation and deadline tests passed. |
| End session | Capture stopped and the retained transcript/answer view cleared. |

The final installed-Release meeting and image checks are completed below after packaging. The preliminary system-audio run is not a claim about every later binary's macOS authorization.

## Evidence limits

The tested source uses the official Grok Build 1.0.13 installed on this Mac. The helper remains a separate prerequisite on a new machine. Synthetic speech and a controlled window are used for outbound tests; they do not establish all real meeting receivers, accents, devices or display configurations.

The app is an ad hoc signed preview, not notarized. macOS capture grants may need to be repeated after an ad hoc rebuild. Developer ID/notarization, a separate clean macOS account, macOS 15 runtime, and a broad Zoom/Teams/browser receiver matrix remain outside these checks. The old four-hour soak was not repeated.
