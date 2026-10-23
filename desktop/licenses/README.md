# Dependency notices

`Resources/ThirdPartyNotices.html` is generated from the locked Tauri production graph, including the shared engine and credential crate. It is bundled with the Mac and Windows/Linux applications. Build/test tools are excluded. System platform components retain their own licenses.

To refresh using the free open-source Cargo About tool (not required for ordinary app builds):

```sh
cargo install cargo-about --version 0.9.2 --locked --features cli
cargo about generate --locked --fail --manifest-path desktop/app/src-tauri/Cargo.toml --config desktop/licenses/about.toml --target x86_64-pc-windows-msvc --target aarch64-pc-windows-msvc --target x86_64-unknown-linux-gnu --target aarch64-unknown-linux-gnu desktop/licenses/notices.hbs --output-file Resources/ThirdPartyNotices.html
```

This may retrieve missing upstream license text over the network. Inspect generated changes when updating Cargo locks. Cargo source packages and upstream repositories provide the corresponding dependency source.
