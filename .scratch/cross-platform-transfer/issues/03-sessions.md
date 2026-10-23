# 03: Origin-scoped cookie and session migration

Status: done
Label: ready-for-agent
Blocked by: 01 Portable desktop transfer
Spec: ../spec.md

## What to build
Explicitly select origins and consent; transfer supported cookie metadata/values through sealed transport; distinguish cookie verification from confirmed authentication and report required re-login. Prove outcomes against a local synthetic login service.

## Acceptance
Use the approved complete transfer/recovery and sensitive-data boundaries in the spec. No personal account migrations, paid services or unsupported acceptance claims. Record commands, observed outcomes and remaining runtime gaps.

## Evidence / remaining checks
Sealed Rust/WebCrypto capture/apply and local authentication fixture pass in implementer worktree; negative/cleanup tests and integration pending.

Completed integrated implementation and review fixes at 6ce77ea. See docs/cross-platform-verification.md; actual browser/runtime gaps remain explicit.
