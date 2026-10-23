# Browser Bridge desktop preview

Shared Rust engine and Tauri interface for Windows and Linux. The existing SwiftUI Mac app remains the Mac distribution. This is a development preview: production automatic routes on Windows/Linux are empty until actual browser/desktop acceptance passes. Builds and synthetic tests do not grant route acceptance.

## Build locally

Install free [Rust stable](https://rustup.rs/), Node.js 24 and [Tauri system dependencies](https://v2.tauri.app/start/prerequisites/). On Windows, use the free Microsoft C++ build tools and WebView2; on Linux use GTK3/WebKitGTK 4.1 development packages. No paid API, signing service or developer enrollment is required. Packages are unsigned.

From the repository root, set `BRIDGE_TARGET` to your native Rust target triple (for example `x86_64-pc-windows-msvc`, `aarch64-pc-windows-msvc`, `x86_64-unknown-linux-gnu`, or `aarch64-unknown-linux-gnu`). Then:

```sh
cargo test --locked --manifest-path desktop/Cargo.toml
cargo build --locked --release --manifest-path desktop/Cargo.toml --package bridge-host --target "$BRIDGE_TARGET"
node desktop/app/scripts/prepare-resources.mjs
cd desktop/app
npm ci
npm run build -- --target "$BRIDGE_TARGET" --bundles nsis
```

Use `--bundles deb,rpm,appimage` for x64 Linux, or `--bundles deb,rpm` for ARM64 Linux. PowerShell users set `$env:BRIDGE_TARGET` and use `$env:BRIDGE_TARGET` in commands. `BRIDGE_HOST_BINARY` can point to an explicit compiled host when using a custom Cargo target directory. Never set validation/state environment overrides in a normal installation.

## Package matrix and evidence

The public `Desktop preview packages` workflow uses standard free public GitHub runners. Artifacts include SHA-256 inventories and explicit pending runtime checks. Windows x64 builds run on Windows Server; they do **not** establish Windows 10/11 desktop behavior. Windows 11 ARM64 and Ubuntu 24.04 ARM64 use native standard runners. Linux packages target Ubuntu 24.04; Debian 13 and Fedora 44 x64 packages have separate container install/library checks; interactive desktop compatibility still needs real checks. ARM64 AppImage is not distributed until its packaging checks pass.

Requested desktop targets: Windows 10 x64, Windows 11 x64/ARM64, Ubuntu 24.04 x64/ARM64, Debian/Fedora x64. Interactive installation, per-user host registration, browser permissions, lifecycle and session continuity remain pending where there is no evidence. Sandboxed Snap/Flatpak browser connectors are not assumed compatible.

## Privacy and recovery

Normal captures contain browsing data. Keep state and backups private, preferably on an encrypted disk; filesystem permissions are not encryption. Use disposable profiles for validation. Never upload real captures, credentials, cookie envelopes or receipts. Sensitive operations require their own per-transfer consent and report credentials, cookie application and authenticated-session results separately.
