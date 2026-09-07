# App surface, privacy and shutdown verification

The reviewed integration covers `ApplicationModel`, Settings, the companion `NSPanel`, native answer text, the region picker and app-delegate wiring. The focused fixes preserve the primary subscription connection and optional API-key choice. No genuine credential or user account was accessed by these tests.

## Corrected behavior

Profile and session-context edits now propagate synchronously from observable model setters. The generation coordinator invalidates prepared requests when selected context changes and purges prior generated suggestions that could contain the deselected material. A held-screenshot regression proves that deselecting a profile before outbound inference prevents its content from reaching either that request or a subsequent request through generated history; actual conversation provenance is retained.

Screen intent is prepared synchronously through session/selection tokens, then committed through a single owned worker. Rapid changes coalesce to the latest desired mode/source pair. An async inventory result is published only if its session and consent revision still match. Ending a session invalidates outstanding screen work, clears the source selection and resets consent. Cancelling a region change preserves the previous crop; a late region result from display A cannot be applied to display B or to a later session. No cancellation implicitly broadens a crop to a full display.

Shutdown marks the application as closing before suspension, rejects new task-starting/mutating commands, cancels and awaits owned setup, model, validation, credential, import, inventory, connection and screen work, and flushes the latest valid nonsecret preference snapshot. Debounced preference saving and connection changes use one coalescing worker each. A cancelled pending save cannot recreate profiles after Clear local data, including during later shutdown. The model-removal choice is captured when clearing begins. Subscription local-deletion success is checked independently of remote revocation.

Credential/connection changes invalidate the result of an older validation request. The UI cannot treat a previous connection's test result as validation of a new connection. New-session readiness remains false while the connection is being applied. Transcription-only mode rejects edits during an active/preparing session, so its label cannot falsely promise local-only operation while the coordinator still has automatic answers enabled. Other session-level AI options are disabled in Settings until the session ends.

Explicit resume first supplies the current paused/failed source configuration to the coordinator; resuming a previously off source can enable that source for the next start. Merely pressing a source shortcut while idle does not silently alter the next session's enabled sources. Detailed answers are forwarded as an explicit request; expanding the current answer still only changes presentation.

`NativeAnswerView` remains a native noneditable/selectable text view with literal text and fenced-code styling. The hidden-window test exercises real AppKit layout, verifies usable text width/height and selection, and appends an incomplete code fence through completion, checking code/prose fonts. It neither launches an external browser nor renders HTML/remote resources.

Native source-list failures now preserve only an allowlisted error domain and numeric code. A ScreenCaptureKit `-3801` is specifically identified as denied capture authorization; other native failures are not automatically blamed on permission. Localized descriptions, error user-info, unknown domain text and window titles are not copied into this diagnostic. This enables classification of a real app-bundle failure without assuming that ad-hoc signing or TCC is its cause.

## Executed tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'ApplicationModelTests|ContextSelectionPrivacyTests|NativeAnswerLayoutTests'
```

On 2026-09-07 at 14:05:25, **11 tests passed with zero failures in 0.651 s**. These tests cover:

- preserving a crop after cancel, rejecting a crop for a changed source, and rejecting a crop after stop;
- discarding source inventory after consent revocation;
- rejecting new session/mutation commands after shutdown;
- writing the latest preferences when quit arrives during debounce;
- ensuring Clear local data is not undone by pending save or subsequent quit;
- rejecting an active-session transcription-only edit;
- retaining approved native error domain/code while removing private or unknown diagnostic text;
- deselected profile/history exclusion around a suspended screenshot;
- native text layout and incremental code-fence styling.

The first implementation of the transcription-only rejection used an observable property's `didSet` to restore itself; the new regression caused a test-process crash from recursive observation. It was replaced by a guarded computed accessor over observable storage. The same regression then passed; no assertion was weakened or disabled.

## Verification boundary

These deterministic tests use synthetic text, temporary preference directories and isolated test credential providers. Native text layout is tested in a hidden window, not by a mocked renderer. The tests do not establish actual frontmost-app behavior, keyboard selection, Spaces/fullscreen behavior, display unplug/rotation behavior, a physical region drag, real microphone/system capture or the receiver's view of a shared display. Those require separate app-bundle/platform checks. The opt-in passive-panel focus test and any actual TCC/device checks are recorded separately by the main verification workflow. Permission flags and successful source listing are not presented as proof of audio delivery or universal overlay capture privacy.
