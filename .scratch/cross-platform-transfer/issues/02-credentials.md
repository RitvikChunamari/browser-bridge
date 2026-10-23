# 02: Credential migration step

Status: done
Label: ready-for-agent
Blocked by: 01 Portable desktop transfer
Spec: ../spec.md

## What to build
Consent to browser-managed credential import/export, handle supported password CSV/provider flows with authentication prompts, and protect temporary sensitive data without putting values in normal receipts or logs.

## Acceptance
Use the approved complete transfer/recovery and sensitive-data boundaries in the spec. No personal account migrations, paid services or unsupported acceptance claims. Record commands, observed outcomes and remaining runtime gaps.

## Evidence / remaining checks
Encrypted vault/consent/temporary cleanup boundary merged 005b5c6; six sensitive tests pass. Desktop UI integrated; native Mac sheet/helper integration in progress.

Completed integrated implementation and review fixes at 6ce77ea. See docs/cross-platform-verification.md; actual browser/runtime gaps remain explicit.
