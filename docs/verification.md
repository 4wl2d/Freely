# Freely verification

The graphite glass and Actions update has a separate [verification ledger](glass-verification.md), including native keyboard/compositor tests and the outstanding receiver matrix. The preceding unified-panel results remain in the [earlier ledger](redesign-verification.md).

The earlier installation, connection and first-meeting checks are documented in [first-meeting-ux.md](first-meeting-ux.md). It distinguishes automated regression checks, live subscription requests, native capture and remaining distribution/compatibility limits.

## Current commands

```sh
./script/test.sh --no-parallel
FREELY_GROK_LIVE=1 ./script/test.sh --no-parallel --filter GrokBuildLiveTests
./script/package.sh
```

The live Grok test uses subscription usage and is disabled in ordinary CI. Native fixtures and pure core tests do not prove microphone permissions, actual system audio, live vision or provider account access.

## Preserved original evidence

The [2026-09-07 verification ledger](archive/verification-2026-09-07.md) preserves the original build, test, microphone, STT and four-hour-soak results. [Original packaging evidence](archive/packaging-evidence-2026-09-07.md) preserves the exact old bundle and archive hashes. `Benchmarks/results/` files from that run remain byte-for-byte unchanged by the rename.

The long soak exercised sparse local inference alongside sustained remote inference; it was not a four-hour live Grok call or a broad device/receiver matrix. These old measurements are not presented as re-run results for Freely 0.2.0.
