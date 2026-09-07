# Subscription OAuth evidence and limits

Subscription sign-in is the primary configured connection; an xAI API key remains an explicit optional method. The native OAuth implementation is complete at the transport/state-machine level, but a working subscription-funded MeetingCopilot integration is **blocked by provider registration and unverified inference entitlement/routing**. The build contains no provider-issued client ID. It stops before opening sign-in when that value is absent. No Grok Build/OpenCode client ID, callback identity, stored credential or consumer session cookie is reused.

## Source ledger

Access date: 2026-09-07. These official sources establish the following separate facts:

| Source | Established fact | What it does not establish |
| --- | --- | --- |
| [xAI OpenID discovery metadata](https://auth.x.ai/.well-known/openid-configuration) | Issuer `https://auth.x.ai`; `/oauth2/authorize`, `/oauth2/token`, `/oauth2/revoke`; authorization-code and refresh grants; public-client token authentication `none`; PKCE `S256`; listed `api:access` and `offline_access` scopes. | There is no `registration_endpoint` in the observed metadata. A listed scope does not grant it to this app or prove subscription-funded inference. |
| [Official OpenCode subscription integration](https://x.ai/news/grok-opencode) | xAI supports subscription-backed OAuth for that named integration. | It does not authorize MeetingCopilot to impersonate OpenCode or reuse that client's registration. |
| [Grok Build enterprise deployment](https://docs.x.ai/build/enterprise) | The documented Grok Build route uses `cli-chat-proxy.grok.com` for inference and `auth.x.ai` for authentication; `api.x.ai` is documented separately as the direct API-key path. | A generic OAuth token accepted by `api.x.ai/v1/responses`, a supported custom-app subscription proxy contract, and MeetingCopilot billing entitlement were not verified. |
| [Grok Build overview](https://docs.x.ai/build/overview) | Grok Build offers browser authentication and supported CLI/ACP integrations. | This does not satisfy the requested independent native URLSession Responses application by itself. MeetingCopilot does not launch another coding client or enable that client's tools. |
| [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252.html), [RFC 7636](https://www.rfc-editor.org/rfc/rfc7636.html), [RFC 6749](https://www.rfc-editor.org/rfc/rfc6749.html) | Native browser authentication, PKCE S256, state/callback validation and authorization-code/refresh token semantics. | Protocol conformance is independent of provider approval and paid-plan entitlement. |

No public provider-issued registration for this app or general custom-native subscription enrollment endpoint was established in the official material searched. The required external next step is an xAI-approved native client registration for MeetingCopilot with its exact callback, approved scopes, and documented subscription inference route/billing terms. A client ID from another product is not a substitute. Real text streaming and transcript-plus-image generation must then be tested independently under that approved account. No live login, subscription deduction, API credit consumption or entitlement test was performed during these tests.

## Implemented behavior

`SubscriptionAuthentication` uses `ASWebAuthenticationSession`. Password entry remains in the browser's authentication boundary. Each attempt generates independent 256-bit random verifier/state values and sends only the SHA-256 verifier challenge to authorization. The callback must match the app's scheme, host, exact path, state and optional issuer; duplicate/ambiguous parameters, credentials, ports, fragments and oversized/control-character payloads are rejected. The code is exchanged with the original verifier and this app's configured client ID. Only the fixed verified xAI authorization endpoints are used; network redirects are rejected.

The native callback bridge resolves completion, cancellation, startup failure and a ten-minute user sign-in timeout exactly once. Cancellation is completed locally even if the OS never calls its completion handler. Late callbacks cannot complete a newer login. A failed `start()` followed by a callback cannot double-resume a continuation. Root code can still present an actionable registration-required state without opening any browser or sending an authentication request.

`OAuthTokenClient` owns the mutable token lifecycle in one actor. Its synchronous `OAuthTokenStoring` primitive makes epoch validation and Keychain save one non-suspending operation. Complete access/refresh/expiry/client/scope sets rotate atomically in a separate device-bound Keychain item; raw tokens are absent from preferences and errors. Returned token data is validated and bounded, and refresh preserves previous scopes/token when the provider omits unchanged fields. Short-lived tokens receive a proportional refresh margin instead of causing immediate refresh loops.

At most one refresh and eight waiting consumers exist; one waiting consumer's cancellation does not cancel another consumer. The last canceled consumer cancels and awaits native HTTP termination. Configuration changes, logout and shutdown fence every returning token and cancel owned work. HTTP response bodies are capped at 64 KiB, at most four native auth HTTP jobs are owned, request inactivity is limited to 20 s and total resource lifetime to 30 s. Cleanup awaits URLSession's invalidation acknowledgment, including cancellation during a pending credential load before an LLM stream exists. Invalid-grant responses expire the stored session; provider error descriptions are discarded.

Logout removes the local token set before remote revocation. Corrupt stored data is still removable. Local deletion failure and unconfirmed remote revocation have distinct outcomes. `SubscriptionAuthentication.disconnect()` is `@discardableResult async -> Bool`: false means local deletion failed, true means local deletion succeeded (whether or not remote revocation was confirmed). Callers must not claim credentials were cleared when this returns false. `PreferredCredentialStore` returns only the explicitly selected connection and rejects credentials arriving after a method change; it never falls back silently from subscription to an API key. Its `delete()` remains the optional API-key deletion operation; full local-data clearing must also disconnect subscription storage.

The application composition root must stop active generations before changing/disconnecting their connection, because a Responses request that already received a bearer token belongs to its LLM provider, not to the OAuth client. A stored OAuth token and the UI's connected state are not proof that this application's subscription can fund Responses or vision requests.

## Executed validation

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MEETINGCOPILOT_KEYCHAIN_TEST=1 \
  swift test --filter 'OAuthTests|OAuthWebSessionTests|OAuthKeychainTests'
```

The 05:25:25 run on 2026-09-07 passed **23 tests, zero failures, 0.108 s**. It covered the RFC PKCE vector, random challenge format, callback rejection cases, exact-once continuation resolution, no-callback browser cancellation, failed-start/late-callback races, browser timeout, refresh deduplication, single/last waiter cancellation, configuration/logout/code-exchange fencing, malformed tokens, response bounds, short-token margins, method changes, corrupt-token removal, typed revocation/deletion outcomes and the public disconnect return value.

The enabled Keychain test created, updated, read and removed only a UUID-namespaced synthetic token item. Browser and HTTP fixtures are confined to test targets. No genuine user token, API key, browser session, account or client registration was inspected. These tests do not count as live xAI login, subscription billing or text/image generation verification.


## Final cancellation-fixture correction

Final uninstrumented Debug and Release app suites each collected 141 tests and executed/passed 139, with two opt-in skips. Keychain and native hotkey flags were enabled; [exact results](../Benchmarks/results/regression-verification.json) identify commands, logs and their hashes. Production OAuth source was restored byte-for-byte after temporary synthetic-request tracing.

The test server now registers its worker before synchronous response headers and serializes notification delivery with cancellation. A deterministic regression demonstrated forbidden post-stop notifications before this correction. Trace evidence also showed that URLSession invalidation can precede the custom server stop callback; the test now waits at most 200 two-millisecond polling intervals for that separate observation, then fails explicitly. Its original cancellation, zero-save and positive-stop assertions remain. Request-start waits also fail on timeout. Earlier stalled/failed runs are preserved; no production teardown threshold was relaxed and no live OAuth success is inferred.
