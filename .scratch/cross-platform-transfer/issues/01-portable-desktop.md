# 01: Portable desktop transfer

Status: done
Label: ready-for-agent
Blocked by: None
Spec: ../spec.md

## What to build
Connect exact profiles and run a complete portable-data transfer with backups, destination preservation, observed verification, receipts and recovery through a shared engine/native host and Windows/Linux desktop interface.

## Acceptance
Use the approved complete transfer/recovery and sensitive-data boundaries in the spec. No personal account migrations, paid services or unsupported acceptance claims. Record commands, observed outcomes and remaining runtime gaps.

## Evidence / remaining checks
Implemented in af55acd. Rust helper journey, interruption/resume, destination preservation and rollback pass against synthetic APIs. Tauri shell compiles on macOS. Windows/Linux real browser/runtime acceptance remains pending; production routes are guided.
