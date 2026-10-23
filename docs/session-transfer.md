# Origin-scoped session transfer

This preview has **no accepted real browser/OS session route**. Production start/retry are gated; the isolated contributor journey exercises the complete implementation without personal accounts. Cookie APIs do not bypass device binding, passkeys, website expiration, token rotation or a server's requirement to authenticate again.

## Consent and scope

Select one to twenty exact HTTPS origins with no page paths, credentials, wildcards or nondefault ports. HTTP is allowed only for loopback synthetic services; browser host permissions cover that loopback host across ports. Each browser's connector requires its own explicit user-gesture permission grant for `cookies` and the selected sites; granting browser permission does not start a transfer. A new transfer or restaging also requires app consent.

Cookies are host-scoped, not generally origin-isolated. This initial conservative adapter accepts only host-only cookies on the selected exact host, with secure cookies on HTTPS and default non-container stores. Domain-wide cookies, partition keys, first-party domain isolation, containers, unsupported SameSite policies, expired values and conflicting destination cookies fail closed. Nonselected subdomains are excluded. Existing identical cookies are retained; conflicting destination values are never overwritten. Source cookies are read, never changed. Native browser/API prompts may still appear. Unsupported cases require ordinary sign-in.

## Public engine requests

All requests use `Engine::dispatch(Value)` and require no renderer access to keys or cookie values.

| Command | Input | Result |
| --- | --- | --- |
| `sessions.plan` | `sourceId`, `destinationId`, `origins: string[]` | `eligible: false`, `readiness: "unverified"`, normalized origins, blockers, warnings |
| `sessions.start` | Same, `consent: true` | Currently fails closed until real route acceptance; no cookie capture/application |
| `sessions.status` | Optional `sessionId` | `{sessions: [redacted receipts]}` |
| `sessions.retry` | `sessionId`, renewed `consent: true` | Production remains gated; trusted disposable validation restages with a new ID |
| `sessions.confirm` | `sessionId`, `confirmedSignedIn: boolean` | Updated receipt; only allowed after independent cookie verification |
| `sessions.cleanup` | `sessionId` | Explicit browser ephemeral-state cleanup, removal of sealed transport records, retained redacted receipt |

Receipt IDs use field `id`; action requests use `sessionId`. Receipt fields include phase, source/destination connection IDs, selected origins, timestamps, cookie counts (`captured`, `applied`, `existing`, `verified`), and `sessionOutcome`. Outcomes are `unverified`, `userConfirmed`, or `reloginRequired`. `userConfirmed` is explicitly a human confirmation, not a programmatic authenticated-session test. Receipt/status never contains cookie names/values, encrypted payloads, derived keys or private keys.

The trusted Rust `validate_session(request, disposable_root)` method enables the same pipeline only when engine state and **all** connected filesystem profiles are beneath an explicit disposable root. It accepts the start fields; retry accepts `command: "sessions.retry"`, `sessionId`, and renewed consent. Desktop/native JSON offers no validation bypass. Contributor tests construct trusted OS caller fixtures; production native callers still require actual observed installed-browser identity and the stable allowed extension origin.

## Transport and recovery

The app generates an ephemeral P-256 ECDH secret. The destination generates a nonextractable ephemeral WebCrypto key. Source cookies are sealed with the app public key **before** returning from the sensitive module; only the sealed envelope and counts enter the connector result cache/native queue. The app decrypts into a zeroizing temporary buffer and immediately reseals for the destination. HKDF-SHA256 uses `browser-bridge-cookie-v1` salt and transfer ID/role/normalized-origin context; AES-256-GCM authenticates that context with a fresh 96-bit random nonce. Public keys use uncompressed SEC1/base64; envelopes contain publicKey, nonce and ciphertext/tag. Payloads are capped at 256 KiB before sealing.

The destination checks scope and every conflict before the first write, then verifies cookies by a fresh API read against its memory-only expected values. Cookies are not put into ordinary portable captures. Private/derived keys and plaintext are never written to durable state; Rust plaintext buffers/derived keys are zeroized on drop. JavaScript clears its mutable expected values and discards key references after verification or cleanup; browser process memory/GC is not a promise of forensic erasure.

Native results for sensitive operations have a strict field allowlist and numeric counters. Unsealed result fields are rejected before persistence. Sensitive browser errors are replaced with fixed text before storage, including the connector's ordinary result cache. Expired/restarted app or browser keys cannot silently recover old ciphertext: interruption requires explicit renewed consent and restaging. Browser ephemeral state expires after five minutes and is purged on subsequent operation; service-worker restart discards it immediately.

Cleanup holds the same sensitive coordinator lease and rejects a claimed pending command. It cannot silently unlock an in-flight apply. Browser cleanup acknowledgments are required before a successful cleanup report; disconnected connectors may need to reconnect first. Applied session cookies are **not** removed by transport cleanup; a partially completed apply may require reviewing the destination and signing in again. Restaging never overwrites conflicting existing values.

## Evidence and limits

`cargo test --manifest-path desktop/Cargo.toml` exercises actual Rust/WebCrypto interoperability through native pairing/jobs and a disposable Node browser API fixture. The local HTTP fixture always returns status 200, but its explicit `authenticated` predicate is false without the synthetic session cookie and true only with the expected token. The engine still reports `unverified` after cookie verification; the test separately exercises human `reloginRequired` confirmation. Tests scan durable state for the fixture cookie value/private-key fields and check that plaintext native results are rejected and sensitive error text is redacted.

`node --test Tests/Sessions/sessions.test.mjs` checks permission-before-read, partition/container/domain/security rejection, exact-origin validation lost-key restaging and an authenticated sealed destination-conflict preflight with zero writes. These are synthetic API tests on macOS arm64, not real Windows/Linux browser permission, cookie-policy or login acceptance. Real user desktop validation remains pending and no automatic route is enabled from these tests.

Cryptographic interfaces follow [RustCrypto P-256 ECDH](https://docs.rs/p256/0.13.2/p256/ecdh/index.html), [RustCrypto AES-GCM](https://docs.rs/aes-gcm/0.10.3/aes_gcm/) and [WebCrypto deriveKey](https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto/deriveKey). Cryptographic library use and passing interoperability tests do not replace independent security review.
