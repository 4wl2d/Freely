# Verification evidence archive

The [preview release](https://github.com/4wl2d/Freely/releases/tag/v0.1.0-preview) preserves the tested app, original Git history, and selected original verification evidence. The [evidence archive](https://github.com/4wl2d/Freely/releases/download/v0.1.0-preview/MeetingCopilot-verification-evidence.tar.gz) contains 108 files: build/test/packaging output, source/artifact hash manifests, preserved failed runs and canonical public-corpus/synthetic STT traces.

[The index](../Benchmarks/results/publication-evidence-index.json) lists every archived path, byte count and SHA-256. Paths inside the archive mirror the old workspace; temporary output is under `external/tmp`. Links to historical local logs in the evidence ledgers download this archive. Historical absolute paths in raw records are provenance, not installation instructions. Downloaded weights, raw audio, user profiles, application preferences and credentials are not included.

The original three-commit Git history is available as [MeetingCopilot-original-history.bundle](https://github.com/4wl2d/Freely/releases/download/v0.1.0-preview/MeetingCopilot-original-history.bundle). It preserves the original `ef16d1c`, `5c93c7b` and `ee0b776` references used by verification records. See [history](history.md) for how the first public import was organized.

To inspect the original history in a separate directory:

```sh
git clone MeetingCopilot-original-history.bundle original-history
```

Each release asset has a `.sha256` companion. Verify a downloaded file with `shasum -a 256 -c <asset>.sha256` from its download directory. The application archive is an ad-hoc-signed local preview; it is not notarized and the unresolved OAuth/capture acceptance checks remain in [verification](verification.md).
