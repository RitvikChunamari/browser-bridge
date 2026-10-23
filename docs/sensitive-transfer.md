# Browser-managed credential transfer

The portable `bridge-sensitive` crate offers a separate sensitive-data journey. It does not read/decrypt browser credential stores, bypass browser or OS authentication, move device-bound keys, or claim independently verified browser import.

## Public integration

`CredentialManager::new(root: PathBuf) -> Result<CredentialManager, CredentialError>` establishes a dedicated user-only credentials directory. The manager is cloneable and Send + Sync; calls serialize using a file lock. Do not pass a general-purpose documents/home directory as its root. Use the app's separate credentials subdirectory. `dispatch(serde_json::Value)` accepts these commands (also with a `credentials.` prefix):

| Command | Required request fields | Reply |
| --- | --- | --- |
| protect | path, passphrase, consent:true | vaultId, count, createdAt (epoch seconds), encrypted:true, sourcePreserved:true, notice |
| list | none | vaults:[{vaultId,count,createdAt}], stages:[{stageId,vaultId,expiresAt}], notice |
| stage | vaultId, passphrase, consent:true | stageId, vaultId, temporaryPath, expiresAt, sensitive:true, notice |
| cleanup | stageId | stageId, cleaned:true, outcome:"cancelled-or-cleaned", verified:false, sourcePreserved:true |
| confirmImport | stageId, confirmed:true | stageId, cleaned:true, outcome:"user-confirmed", verified:false, sourcePreserved:true |

Passphrases must contain 12–1024 UTF-8 bytes. `CredentialError` exposes static `code` and `message`; Display/Debug never includes the request, credential values, browser filenames or parser errors. Callers must likewise avoid logging raw requests, passing them through native-job queues, or persisting passphrases. `temporaryPath` is intentionally returned only to the sensitive UI for the browser's native import picker; keep it out of ordinary transfer receipts. The library never opens arbitrary processes or interprets CSV contents as code.

## User journey

1. Explain that this step handles passwords separately. Have the user export passwords using the source browser/provider's supported UI and complete its authentication prompts. Explicit consent authorizes reading the chosen CSV and protecting it. The original export is never modified or deleted.
2. Protect the selected export with a new vault passphrase. The app cannot recover a forgotten passphrase. List returns only vault metadata after restart. Vault count is informational and does not establish import success.
3. Obtain renewed consent before unlocking/staging a CSV. Send the returned temporary file to the destination browser's own password-import workflow, with the user completing any OS/browser authentication. Source CSV columns/rows are preserved for browser handling. Validation requires exactly one each of url, username and password headers; extra vendor columns are retained. Browser differences and duplicate handling remain the destination's responsibility.
4. Let the user record the browser-reported result. `confirmImport` records **user-confirmed**, explicitly **verified:false**, and removes only the generated stage. Cleanup also cancels/removes only that stage. Neither action deletes the encrypted vault or original source export.
5. Stages expire after 15 minutes. Expired files are removed on the next manager operation or app startup. The shell should poll `list` while open and offer immediate cleanup; this crate does not run a background scheduler while the app is closed. An interrupted step may require renewed staging and consent. A stage alone proves neither saved-password availability nor successful login.

## Protection and recovery

Vault schema 1 seals the original CSV with XChaCha20-Poly1305 and a fresh cryptographic salt/nonce. Argon2id v1.3 uses 64 MiB, three iterations and one lane to derive a 256-bit key from the vault passphrase. Format version, UUID, creation time and entry count are authenticated as associated data. KDF costs are fixed by the supported schema, not trusted from attacker-controlled vault parameters. No raw key or passphrase is durably saved. Main secret buffers use zeroizing wrappers; the app cannot guarantee erasure of every library/runtime, renderer, swap or OS copy.

Input is limited to 8 MiB and 100,000 CSV records; encrypted storage reads are bounded. Paths must be absolute and reject symlink/reparse traversal. Files are owner-readable/writable and directories owner-only on Unix; Windows uses an owner-only inherited ACL established through a fixed PowerShell script with the path supplied via a process environment variable, never interpolated into code. Windows ACL behavior still needs actual Windows execution.

Plaintext is written directly to its unique final stage filename only after expiry metadata is durable. A crash during writing therefore leaves an identifiable owned stage eligible for expiry cleanup, not an untracked plaintext temporary file. Normal vault/metadata writes use private temporary files and atomic replacement. Concurrent calls serialize at the protected-store lock. File deletion is logical cleanup, not guaranteed forensic erasure on SSDs, filesystem snapshots or backups. Protect the machine/disk accordingly; source export handling remains explicit because the original is preserved.

## Passkeys and signed-in sessions

Password CSV is not a passkey export. Use a credential provider's supported exchange where that particular provider/OS/browser route exists, or retain the provider/re-register a passkey with the website. Current [Chrome desktop help](https://support.google.com/chrome/answer/13068232) has a generic passwords-and-passkeys introduction but documents password CSV steps; that does not establish universal desktop passkey file interchange. [FIDO credential exchange](https://fidoalliance.org/specifications-credential-exchange-specifications/) defines portable credential standards; individual provider implementation remains a separate check.

Cookies/session continuity are a different opt-in pipeline. A successful password import does not prove cookie transfer, and copied cookies do not prove signed-in state. Device binding, expiry, server rules and authentication prompts may require a fresh login. No actual-account success is claimed by this crate.

## Validation boundary

Tests use invented CSVs only and exercise the approved sensitive journey through the public manager API: protection/staging/confirmation/cleanup, explicit consent, restart expiry and vault recovery, original preservation, bounded CSV validation, redacted errors/status, ciphertext tampering, wrong passphrases and Unix permissions/symlink rejection. File-output inspection verifies the published encrypted vault boundary, not personal browser contents. The test clock is an injectable system boundary (`with_clock`); it is not exposed by the desktop command dispatcher.

Real browser/OS authentication UI, destination import and passkey/provider exchange have not been exercised here. A build or synthetic vault test cannot certify those outcomes. Windows/Linux native execution and ACL behavior remain target-specific verification work.

Primary browser references: [Chrome password CSV](https://support.google.com/chrome/answer/13068232), [Firefox export](https://support.mozilla.org/en-US/kb/export-login-data-firefox), [Chrome DBSC device binding](https://blog.google/security/protecting-cookies-with-device-bound-session-credentials/). Crypto implementation uses the free/open-source RustCrypto `argon2` and `chacha20poly1305` crates; no hosted service or paid dependency is introduced.

Observed checks on the Mac build host: the first public journey test initially failed because the manager API was missing, the restart-expiry slice failed before the clock boundary was added, and the duplicate-header CSV test exposed acceptance of ambiguous files before validation was tightened. Final `cargo test --workspace --manifest-path desktop/Cargo.toml` passed three engine journey tests and six sensitive journey tests, plus documentation targets. The task-local Rust toolchain was supplied through explicit CARGO_HOME/RUSTC/RUSTDOC/CARGO_TARGET_DIR paths; no system toolchain or paid service was installed. `git diff --check` passed. Actual destination password-manager imports remain unverified.

## Native Mac integration

The SwiftUI app exposes a separate Passwords sheet with a native CSV picker, secure passphrase fields, separate protection/staging consent and a persistent vault list. `Contents/MacOS/bridge-credentials` accepts exactly `--root <trusted-app-directory>` and one JSON request on stdin (64 KiB bound). It returns a bounded JSON envelope `{ok:true,result}` or `{ok:false,error:{code,message}}`; no password or passphrase is a command-line argument. Output is consumed directly by the sensitive view, with stderr discarded and no ordinary transfer queue involved. Swift subprocess work runs off the main actor with a Data-only boundary. UI passphrase fields are cleared after dispatch and on dismissal; Swift/renderer/runtime memory copies cannot be guaranteed erased.

The native store lives in Application Support/BrowserBridgeCredentials. The sheet polls while visible and cleans owned stages on normal dismissal. An application termination delegate waits for any active sensitive operation and requests cleanup before allowing normal quit; an observed failure offers Cancel quit or Quit anyway with a residual-plaintext explanation. Force quit, crash and power loss can retain staged plaintext until the next manager startup/action; this is not a secure-erasure guarantee. The existing portable/browser transfer manager is unaffected. Passkeys and browser sessions are not represented as completed by this password-only UI.

A synthetic subprocess integration test exercised the helper's protected export, persisted listing and redacted malformed-input handling, without real browser data. Build verification and any native UI/runtime checks are reported separately; compiling the sheet does not prove the destination browser imported credentials.

Mac follow-on verification: `swift build` successfully compiled the native app and all Swift command-line targets. `cargo test -p bridge-sensitive --manifest-path desktop/Cargo.toml` passed six manager tests and one helper subprocess journey covering protect/list/stage/confirm/cleanup plus malformed and oversized stdin; documentation targets passed. The Passwords entry is disabled in `--demo`. Native rendered-sheet inspection, actual browser password import and app-exit behavior remain runtime checks to be exercised separately; no personal credentials were read.
