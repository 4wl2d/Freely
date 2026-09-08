# Packaging Freely

`script/package.sh` builds the Release executable and stages `dist/Freely.app` with bundle identifier `local.freely.app`, version `0.2.0`, and build `2`. It checks the code signature, archives the bundle as `Freely-0.2.0-macOS-arm64.zip`, and writes a SHA-256 sidecar. Resources, the model manifest, icon and license notices are included. Speech weights are downloaded separately; Grok Build is an external prerequisite for subscription mode.

The first-meeting check and final artifact verification are recorded in [first-meeting-ux.md](first-meeting-ux.md). The [current release](https://github.com/4wl2d/Freely/releases/tag/v0.2.0-preview) is a preview.

## Signing

The default artifact is ad hoc signed with hardened runtime. It is not notarized. `FREELY_SIGN_IDENTITY` and `FREELY_NOTARY_PROFILE` enable the existing Developer ID/notarization workflow when valid credentials are supplied. Debugger entitlement `get-task-allow` is added only by the explicit `--debug` launch mode and is excluded from normal and Release bundles.

macOS may require explicit first-launch approval and capture permissions. An ad hoc development rebuild can require granting permissions again; tested permissions apply to the tested artifact. No global Gatekeeper or TCC settings are disabled by the scripts.

## Historical provenance

The [original packaging ledger](archive/packaging-evidence-2026-09-07.md) retains the prior artifact names, identities, hashes, failures and inspection commands. Those files belong to the immutable v0.1.0-preview release and are kept for reproducibility.
