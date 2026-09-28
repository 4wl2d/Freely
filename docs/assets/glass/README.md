# Graphite glass and Actions fixtures

Synthetic UI fixtures rendered from the native AppKit/SwiftUI shell. Both dimensions are asserted by `ShellSnapshotTests`. Content-only snapshots use the opaque presentation backing. The desktop images below are actual local display crops over public test backgrounds. These are not recipient screenshots.

| Screen or state | Compact 720 x 520 | Expanded 960 x 700 |
| --- | --- | --- |
| Actions | [Compact](actions-compact.png) | [Expanded](actions-expanded.png) |
| Answer | [Compact](answer-compact.png) | [Expanded](answer-expanded.png) |
| Answers | [Compact](answers-compact.png) | [Expanded](answers-expanded.png) |
| Appearance shortcuts | [Compact](appearance-shortcuts-compact.png) | [Expanded](appearance-shortcuts-expanded.png) |
| Audio speech | [Compact](audio-speech-compact.png) | [Expanded](audio-speech-expanded.png) |
| Connections | [Compact](connections-compact.png) | [Expanded](connections-expanded.png) |
| Context | [Compact](context-compact.png) | [Expanded](context-expanded.png) |
| Diagnostics | [Compact](diagnostics-compact.png) | [Expanded](diagnostics-expanded.png) |
| End session | [Compact](end-session-compact.png) | [Expanded](end-session-expanded.png) |
| Error | [Compact](error-compact.png) | [Expanded](error-expanded.png) |
| Frozen answer | [Compact](frozen-answer-compact.png) | [Expanded](frozen-answer-expanded.png) |
| Generating | [Compact](generating-compact.png) | [Expanded](generating-expanded.png) |
| Incomplete code | [Compact](incomplete-code-compact.png) | [Expanded](incomplete-code-expanded.png) |
| Large text | [Compact](large-text-compact.png) | [Expanded](large-text-expanded.png) |
| Preparing | [Compact](preparing-compact.png) | [Expanded](preparing-expanded.png) |
| Presentation | [Compact](presentation-compact.png) | [Expanded](presentation-expanded.png) |
| Privacy data | [Compact](privacy-data-compact.png) | [Expanded](privacy-data-expanded.png) |
| Profiles | [Compact](profiles-compact.png) | [Expanded](profiles-expanded.png) |
| Readiness | [Compact](readiness-compact.png) | [Expanded](readiness-expanded.png) |
| Screen context | [Compact](screen-context-compact.png) | [Expanded](screen-context-expanded.png) |
| Selection | [Compact](selection-compact.png) | [Expanded](selection-expanded.png) |
| Settings | [Compact](settings-compact.png) | [Expanded](settings-expanded.png) |
| Transcript | [Compact](transcript-compact.png) | [Expanded](transcript-expanded.png) |

## Actual local glass

| Background | Compact | Expanded |
| --- | --- | --- |
| Dark | [Answer](desktop-dark-compact.png) · [Actions](desktop-actions-dark-compact.png) | [Answer](desktop-dark-expanded.png) · [Actions](desktop-actions-dark-expanded.png) |
| Light | [Answer](desktop-light-compact.png) · [Actions](desktop-actions-light-compact.png) | [Answer](desktop-light-expanded.png) · [Actions](desktop-actions-light-expanded.png) |

[Pixel comparison evidence](desktop-evidence.json) checks an interior patch, excluding corners and shadows. The presentation content is byte-identical across both backgrounds.

## Actual output window

[Actions and native text](presentation-actions-readback.png) · [After Hide](presentation-hidden-readback.png)

Magenta text is a deliberate test marker. These images are ScreenCaptureKit readbacks of the actual Freely Presentation window, using the named public CaptureFixture source.
