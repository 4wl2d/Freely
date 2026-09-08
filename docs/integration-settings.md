# Native shortcuts and local preferences

`HotkeyController` is `@MainActor @Observable`. Construct one at the application composition root with an action callback, call `configure(preferences.shortcuts)` after loading/saving preferences, and keep it alive until app termination. Read `statuses[action]?.message` in Settings. Each of the ten `HotkeyAction` cases has a menu equivalent; registration failure must leave that menu action usable. Call `unregisterAll()` before termination. Reconfiguration removes old registrations and disables unresolved conflicts instead of silently assigning two actions to one key.

```swift
let hotkeys = HotkeyController { action in
    // Switch over HotkeyAction and call the corresponding application-owned action.
}
hotkeys.configure(preferences.shortcuts)
```

The implementation uses `RegisterEventHotKey`, exclusive registration and an application Carbon event handler, all on the main thread. `CopySymbolicHotKeys` checks enabled macOS shortcuts before registration. It does not install an event tap, monitor arbitrary key presses, require Accessibility, activate the app, or type into another application. The callback executes only for this controller's registered signature/ID. Handler context ownership uses a retained weak reference so an OS cleanup failure cannot leave a dangling C pointer.

The initial assignments are Control–Option–Command plus `1` through `0`, in this order: start/stop, overlay, answer, capture/analyze, expand, clear, pin, microphone pause, system-audio pause, end session. Settings may choose any supported physical key code with Command or Control, or disable a shortcut by setting its chord to `nil`. `ShortcutKey` supplies a native picker list and `ShortcutChord.label` supplies display text. Labels describe US keyboard positions; other layouts retain physical-key behavior. Bare characters and modifier-only combinations are rejected. This conservative modifier rule works with the macOS 15.0 baseline; Apple's [Sequoia hotkey discussion](https://developer.apple.com/forums/thread/763878) documents version-sensitive restrictions on Option/Shift-only registration. Installed `CarbonEvents.h` was checked on 2026-09-07 for thread affinity, exclusive registration, symbolic conflicts and cleanup semantics. Conflict checks cannot enumerate every app-specific menu shortcut; the app reports actual registration failures and preserves menu alternatives.

`PreferencesStore` is an actor that reads/writes `~/Library/Application Support/Freely/preferences.json` (schema 1). Its `load()` returns defaults when the file is absent and does not write a file. `save(_:)` validates bounds and atomically replaces the file; the directory is mode 0700 and the file 0600. These permissions are not encryption. Corrupt or newer-format files are preserved, produce a typed remediation error, and cannot be overwritten by an automatic save. An explicit `clearConfiguration()` removes this app's preference/profile file and permits a fresh save. Keychain deletion and optional model removal have separate owners in the application's Clear local data action.

`AppPreferences` persists AI, audio, overlay, shortcut and saved-profile choices. API keys, session notes, live screen consent, transcripts, audio, screenshots, generation state and pinned answers have no persistence fields. Screen consent must reset for every new session. An audio application is persisted by bundle identifier, never stale PID. A nil microphone UID follows the current system default. Only English STT is exposed; answer language is independently configurable. Automatic answers are enabled after session start; local-speech triggers and experimental speculation default off.

At most 20 profiles are saved. Each profile has role, professional background, technology stack, project context, answer preferences, vocabulary, custom instructions and imported text. `selectedProfileID` is nil initially. Missing selection never falls back to another profile. Use `preferences.selectedProfile?.selectedContext(for: questionText, maximumBytes: 2_000)` to select bounded relevant paragraphs; show its `isLimited` indicator when context was omitted. The result preserves whole source paragraphs and their field labels, with deterministic lexical relevance ranking. Then pass only its text to the domain `ContextConfiguration.selectedProfile`; the domain builder still owns final request budgeting. `contextText` exposes the full selected profile for editing/simple inspection and should not bypass relevance selection for large imports. Vocabulary text is saved as context, not evidence that the STT backend supports vocabulary hints or permission to rewrite uncertain speech.

`ProfileTextImporter.read(url:)` accepts a user-chosen local UTF-8 `.txt`, `.md` or `.markdown` file up to 128 KiB. It reads a bounded amount, handles a UTF-8 BOM, rejects invalid/empty/binary text, and leaves the original file unchanged. Store the returned derivative only after the user explicitly saves the profile. PDF/scanned imports produce a clear unsupported-format error. The overall JSON file limit is 4 MiB, with tighter per-field profile and overlay/AI setting limits in `AppPreferences.validated()`.

## Executed verification

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer FREELY_HOTKEY_TEST=1 \
  swift test --filter 'PreferencesTests|ShortcutTests'
```

On 2026-09-07, **10 tests passed, zero failures, 0.072 s test execution** (latest run, 04:26:23 local test timestamp). The enabled native test registered an actual Carbon global hotkey, observed an exclusive conflict, reconfigured it, released it and registered it again; it used no keyboard monitoring or synthetic keystrokes. Preferences tests exercised atomic replacement, permissions, corruption/newer-format preservation, explicit reset, profile selection, bounds and import source preservation. Application-owned files compiled in Swift 6 mode with macOS 15 deployment.

Actual physical shortcut activation while another application is frontmost and native Settings interactions remain separate GUI validation. Registration/conflict tests do not establish that every keyboard layout, Spaces or fullscreen workflow was exercised.
