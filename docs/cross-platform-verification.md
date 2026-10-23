# 0.4 preview verification

Implementation reviewed through local integration `6ce77ea`, 23 October 2026. This preview expands the product; it does not establish all-browser one-click acceptance.

## Observed locally

- 33 Swift tests passed, including Zen organization merging and credential expiry lifecycle/demo boundaries.
- 19 JavaScript tests passed across existing capture/import/recovery and sealed session modules.
- 21 Rust tests passed across portable export/transfer/resume/rollback, installer preparation, category selection/permission preservation, sealed Rust/WebCrypto transport, synthetic authentication and protected credential/CLI boundaries. Strict Clippy passed.
- The Tauri shell compiles against the integrated crates. Nineteen rendered desktop-interface checks passed with synthetic native APIs; three connector permission-interface checks passed. These prove UI wiring, keyboard/consent/overflow behavior, not actual OS dialogs or browser permission acceptance.
- Website visitor checks passed at desktop and constrained widths (16 checks), and both metadata tests passed. Preview download links are published only with the corresponding release.
- The Mac app, Swift native host and Rust credential helper contain arm64 and x86_64 slices, target macOS14+, and pass ad-hoc signature checks. Intel runtime remains unverified. Paid signing/notarization was not used.

## Platform build evidence

The public Desktop preview packages workflow builds Windows x64/ARM64 and Ubuntu24.04 x64/ARM64 using native standard public runners. Separate Debian13/Fedora44 x64 container jobs check package installation and native library resolution. Consult the actual workflow run and per-artifact package-report.json for results; configuration alone is not a passed build.

Windows x64 CI uses Windows Server, so Windows10/11 x64 desktop behavior is pending. Windows11 ARM64 runner API tests do not establish interactive browser behavior. Linux container/package checks do not establish GNOME/Wayland, Snap/Flatpak browser compatibility or real sessions. No Windows/Linux VM or physical test machine was available in this workspace.

## Sensitive-data boundary

Synthetic password CSVs exercise consent, encrypted vault creation, wrong keys/tampering, owner-only temporary staging, restart/expiry cleanup, original preservation and explicitly user-confirmed import. Real browser password imports, native Mac sheet interactions and native exit prompts have not been exercised. A crash/power loss may retain temporary plaintext until cleanup on a later app action/startup; deletion is not forensic erasure.

The sealed cookie journey uses actual WebCrypto/Rust cryptography and disposable native-message fixtures. Its local service returns HTTP200 both before and after cookie application, but its explicit authenticated predicate changes only with the expected synthetic token. Cookie verification and human sign-in confirmation remain separate. There is no accepted production session route; start/retry remain gated. Domain cookies, partitions/containers, conflicts and device-bound credentials are not silently activated.

## Browser readiness

The existing native Mac exact-version Chrome156.0.8078.48 → Brave156.1.98.60 Apple Silicon acceptance registry is retained unchanged. No new platform/browser direction or version is enabled by these synthetic checks. Intel and Windows/Linux routes remain guided.

Arc/Safari native scripting capture compiles and has synthetic organization fixtures; actual Automation prompts/captures remain unverified. Native destination Spaces/Favorites and Safari Tab Groups are not created. Dia/Arc availability on Windows does not establish a Windows connector adapter. Available browsers without a trusted native adapter are manual-only; unavailable browsers are excluded by platform.

All migration tests used synthetic credentials, a local service and disposable data. Personal accounts/profiles were not used for test transfers. Dependency notices are bundled; the project remains MIT and uses free/open-source build tools without paid services.
