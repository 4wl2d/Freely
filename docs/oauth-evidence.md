# Grok connection in Freely

## Ordinary subscription connection

Freely uses the installed official **Grok Build** client. `Connect Grok` first checks for a grok.com session, opens `grok login --oauth` when needed, and sends a small test request before reporting success. An existing authenticated Grok Build installation does not need another browser sign-in. An API-key login is not accepted as a subscription connection.

The integration was developed and exercised with **Grok Build 1.0.13**, on macOS 26.6.2. Official references checked on 2026-09-08:

- [Headless & Scripting](https://docs.x.ai/build/cli/headless-scripting): supported machine-friendly requests and incremental output.
- [CLI reference](https://docs.x.ai/build/cli/reference): login, models, headless flags and tool configuration.
- [Enterprise deployments](https://docs.x.ai/build/enterprise): the official client's separate subscription proxy and API-key routes.
- [Official client source](https://github.com/xai-org/grok-build): `GROK_AUTH_PATH`, JSON prompt files and agent profile behavior were checked against the released client in live probes.

### Credentials and request lifetime

Only Grok Build reads and refreshes its `~/.grok/auth.json`. Freely does not decode, copy, log or export tokens. Each invocation has an app-owned temporary `GROK_HOME` and working directory. Other clients' rules, hooks, agents and MCP configuration are disabled. Requests use a minimal Freely profile, with tools disabled; a response advertising tools or MCP servers is rejected. API-key environment variables are not inherited, and the temporary configuration disables API-key authentication.

The request body is written to an owner-only JSON file so meeting text and images do not appear in process arguments. Only public answer deltas enter the app; reasoning and arbitrary provider errors do not enter answers or diagnostics. Completion requires a successful terminal frame and a clean process exit. Output has byte limits, processes have total deadlines, and cancellation waits for process exit before removing temporary files. Normal completion and cancellation remove the temporary client history and logs. A force quit or OS crash can interrupt cleanup; provider-side retention is outside Freely's control.

`Disconnect` clears Freely's enabled connection, while preserving the user's separate Grok Build login. It does not run `grok logout`. Requests never silently fall back to an API key. The Grok Build model controls its output token budget; the UI shows the separate local 128 KiB answer limit instead of claiming API token caps apply.

### Installation

Freely finds Grok Build in `~/.local/bin/grok`, `~/.grok/bin/grok`, `/opt/homebrew/bin/grok` or `/usr/local/bin/grok`. If missing, the connection screen shows an installation link and a retry action. Install from the [official instructions](https://docs.x.ai/build/overview), then return to Freely. The helper is a separate prerequisite; it is not silently downloaded or bundled.

## Optional API key and registered native OAuth

The API-key connection uses the xAI Responses API with a separately stored Keychain key. An advanced native OAuth field remains available only for an xAI-registered Freely integration with callback `freely://oauth/callback` and approved inference access. That registration is not required for the ordinary Grok Build connection.

The [original native OAuth record](archive/native-oauth-2026-09-07.md) documents its transport tests and the historical provider-registration blocker. Its measurements are preserved as historical evidence, not presented as tests of the new Grok Build path.

## Verification

See [the current first-meeting UX record](first-meeting-ux.md) for live outcomes. Automated checks cover answer-only parsing, enabled-tool rejection, EOF/failure handling, output bounds, API-key isolation, subprocess cancellation/deadline/cleanup, legacy data migration and setup readiness. `FREELY_GROK_LIVE=1` enables the explicit subscription smoke test; ordinary CI does not spend subscription usage.
