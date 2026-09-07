# History and provenance

Before its first public import, MeetingCopilot's initial implementation was reorganized into logical, reviewable commits. Those commits present a completed local implementation and its evidence by topic. Their order is not a reconstruction of when each subsystem was written, and no development chronology has been invented or backdated.

The original local Git history is preserved separately. Public import commits may therefore have different identifiers from the snapshots named in build and benchmark records. A historical SHA in an evidence file identifies that original snapshot; it does not imply that a GitHub commit URL with the same SHA will exist in the reorganized public history.

## Original snapshots

| Original commit | Recorded purpose |
| --- | --- |
| `ef16d1c707226a56cd597f684325be27f41f4acf` | Initial native implementation, local STT, subscription-first setup and verification records. This exact commit was used for the clean Git checkout build. |
| `5c93c7bdc04fa3a4dd2aae13a67d71ee5246fc87` | Clean-checkout build evidence and provenance for the then-running paced soak. |
| `ee0b776ef44dbfc7647e9485cae494389315b5b3` | Completed four-hour local-inference soak and remaining acceptance boundaries. |

These are provenance references, not a fabricated series of earlier public milestones. The source/input manifests and recorded commands remain the basis for connecting a result to the bytes that were tested. See [clean-checkout verification](../Benchmarks/results/clean-checkout-verification.json), [packaging evidence](packaging-evidence.md), and [the verification ledger](verification.md).

## Preserved release materials

The [v0.1.0-preview release](https://github.com/4wl2d/MeetingCopilot/releases/tag/v0.1.0-preview) preserves:

- [MeetingCopilot-original-history.bundle](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-original-history.bundle) and its [SHA-256 file](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-original-history.bundle.sha256): the original Git history before public-import reorganization.
- [MeetingCopilot-verification-evidence.tar.gz](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) and its [SHA-256 file](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz.sha256): selected verification logs and canonical benchmark traces. The release publication manifest describes its contents.
- [MeetingCopilot-1.0.0-macOS-arm64.zip](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-1.0.0-macOS-arm64.zip) and its [SHA-256 file](https://github.com/4wl2d/MeetingCopilot/releases/download/v0.1.0-preview/MeetingCopilot-1.0.0-macOS-arm64.zip.sha256): the verified local app artifact. The public release tag is `v0.1.0-preview`; the preserved app's bundle version is `1.0.0`.

After downloading the Git bundle, restore it into a separate directory to inspect an original snapshot:

```sh
git clone MeetingCopilot-original-history.bundle MeetingCopilot-original-history
git -C MeetingCopilot-original-history checkout --detach ef16d1c707226a56cd597f684325be27f41f4acf
```

Original machine paths and run identifiers may appear inside preserved raw evidence. They describe the environment where a measurement was taken; they are not required installation paths. The current documentation and release manifest identify the portable source, artifact and evidence locations.

The import does not turn a local fixture into live service evidence. OAuth registration and subscription inference entitlement, real simultaneous capture, the receiver/display matrix, and Developer ID/notarization remain subject to the [recorded acceptance boundaries](verification.md).
