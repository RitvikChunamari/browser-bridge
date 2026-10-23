# Cross-platform connected migration
Status: ready-for-agent. Baseline: a946d1e. Approved through ask-matt on 23 October 2026.

## Problem Statement
Only one exact Apple Silicon Mac route is accepted for automatic Transfer. Other browser combinations need manual packages; credentials/session continuity and Windows/Linux applications are absent. Users want one coordinated journey after setup without losing existing destination data.

## Solution
Keep the current Mac app working while adding a shared native engine and Windows/Linux desktop app. Coordinate capture, private checksummed backups, normal close/reopen, additive application, independent verification, receipts, resume and conservative rollback. Capabilities describe actual browser/OS/category support. Missing native APIs remain explicit; no route is accepted solely from browser ancestry or a passing build. Credentials and sessions have an explicitly consented sensitive-data step, authentication prompts and separate outcome reporting.

## User Stories
1. As a user, I can choose installed browser profiles on my operating system.
2. As a user, I can connect the exact profile once using the local browser connector.
3. As a user, I can see which categories are portable, approximated, native, archived or unavailable.
4. As a user, I can start an eligible transfer with one Transfer action after setup.
5. As a user, I retain existing destination bookmarks, tabs and groups.
6. As a user, I retain a checksummed private backup before any import.
7. As a user, I see progress and a receipt that records observed results rather than intended counts alone.
8. As a user, I can resume interrupted work without silently duplicating effects.
9. As a user, I can conservatively remove helper-owned additions while keeping original and uncertain changes.
10. As a user, I can opt into a separate credential transfer and respond to browser/OS authentication prompts.
11. As a user, I can use browser-managed password export/import where no supported silent API exists.
12. As a user, sensitive values stay out of normal snapshots, receipts, logs and public artifacts.
13. As a user, I can opt into cookies for explicitly selected origins, not every site by default.
14. As a user, I distinguish a copied cookie from an authenticated login that actually survived.
15. As a user, I am told when device binding, expiration or website rules require fresh sign-in.
16. As a user, I can retain available Arc/Safari/Zen organization with clearly stated native/approximation boundaries.
17. As a user, the original Mac application remains available during the cross-platform rollout.
18. As a user, I can obtain packages for the agreed Windows/Linux target matrix.
19. As a user, I can distinguish cross-built, CI-tested and real desktop/browser-verified support.
20. As a contributor, I can reproduce synthetic migrations without personal accounts or browser data.

## Implementation Decisions
- A Rust engine/native messaging host and Tauri desktop shell provide an explicitly portable native boundary; reuse the existing JavaScript capture/import/verification helper contracts. Keep SwiftUI and the tested Swift engine for Mac during transition; cross-language fixtures protect schema compatibility.
- Platform adapters own browser/profile paths, actual process identity, host registration, user-only state, file locking, normal close/reopen and packaging. No generic force-quit fallback.
- Production route acceptance includes OS/architecture/browser build/direction and evidence. No UI bypass for missing acceptance. A local validation interface is restricted to an explicitly disposable root.
- Shared transfer state is private and bounded. Authenticate native messages using host-origin restrictions, observed caller identity and paired profile secrets. Receipts redact secrets and sensitive values.
- Credential handling uses supported browser/provider flows and explicit consent. No undocumented credential decryption, disabled security policies or silent activation of device-bound sessions.
- Cookie transport is origin-scoped, permission-gated and sealed before durable storage. Keep decrypted values ephemeral; browser session keys and app session keys are not written into ordinary journals. An interrupted sensitive step may require reconfirmation/restaging rather than silently recovering plaintext.
- Verify cookie application separately from session continuity. Use explicit origin-specific verification or user-confirmed sign-in status; generic HTTP success is not proof of authentication.
- Supported targets requested: Windows 10 x64; Windows 11 x64/ARM64; Ubuntu 24.04 x64/ARM64; Debian and Fedora x64 packages. Standard public GitHub Actions only, no paid runners or subscriptions. Windows Server CI does not establish Windows 10/11 desktop behavior. No local Windows/Linux VM is available; unperformed runtime checks remain pending.
- Safari/Arc/Dia are exposed only on their available platforms. Native fields are not blindly written into undocumented stores. Native organization adapters require schema/version and persistence checks.

## Testing Decisions
User approved two external boundaries: complete connection→backup→transfer→verification→resume/rollback journey; and sensitive-data consent/temporary-data/cookie/session-outcome boundary. Use synthetic profiles/credentials and a local authentication fixture service, never personal account migrations. Test unknown routes/capabilities, malformed or oversized frames, symlink/reparse escapes, concurrent coordinators, crash recovery, existing destination preservation and unsupported categories. Compare neutral captures with existing Swift/JS fixtures. Inspect desktop UI at desktop/mobile-like constrained sizes, keyboard/focus/overflow. Build/package each requested target where tools/runners permit; distinguish packaging from actual OS/browser acceptance.

## Out of Scope
Paid signing/store enrollment, cloud migration accounts, paid infrastructure, bypassing device-bound security, transferring browsers that do not exist on an OS, claiming untested routes as automatic, or claiming universal native feature parity. Mobile apps remain future work.

## Further Notes
Research evidence is in the repository's browser capability and platform portability notes. Build the approved slices and continue through validation/publication; do not stop after creating the plan. Preserve the existing Mac release and personal browser data.
