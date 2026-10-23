# Universal Mac build

The 0.4 preview packaging (build 5) contains both Apple Silicon (`arm64`) and Intel (`x86_64`) slices in the app executable the native messaging host and the protected credential helper. Both target macOS 14.0 or later. JavaScript connectors and shared artwork need no architecture-specific variant.

## Build and inspect

Use the free Apple Command Line Tools, Node.js24 and Rust stable. Install the two Rust targets (`rustup target add aarch64-apple-darwin x86_64-apple-darwin`) before building.

```sh
bash build.sh
bash test.sh
lipo -info "outputs/Browser Bridge.app/Contents/MacOS/BrowserBridge"
lipo -info "outputs/Browser Bridge.app/Contents/MacOS/browser-bridge-host"
codesign --verify --strict --architecture arm64 "outputs/Browser Bridge.app"
codesign --verify --strict --architecture x86_64 "outputs/Browser Bridge.app"
codesign --verify --strict --architecture arm64 "outputs/Browser Bridge.app/Contents/MacOS/browser-bridge-host"
codesign --verify --strict --architecture x86_64 "outputs/Browser Bridge.app/Contents/MacOS/browser-bridge-host"
```

`build.sh` builds each product with these commands for each `ARCH` value, `arm64` and `x86_64`:

```sh
swift build --build-system native --scratch-path "work/universal-build/$ARCH" --triple "$ARCH-apple-macosx14.0" -c release --product BrowserBridge
swift build --build-system native --scratch-path "work/universal-build/$ARCH" --triple "$ARCH-apple-macosx14.0" -c release --product browser-bridge-host
```

Separate scratch directories prevent architecture products from mixing. The script combines matching products with `lipo -create`, checks that both architectures are present, assembles a fresh app, ad-hoc signs the nested host first and the enclosing app second **after** `lipo`, and verifies each architecture. Only then does it replace `outputs/Browser Bridge.app`. It uses no paid signing enrollment, store service, remote build service or Rosetta installation.

Native build-system deprecation warnings come from SwiftPM; that backend remains necessary for this repository’s Command Line Tools configuration. The exact cross-compilation target establishes the deployment target; it does not establish runtime acceptance on every macOS release.

## Readiness and validation limits

Intel is **guided transfer only**. `AutomaticRoutes.allows` returns false when compiled for `x86_64`, including for browser versions that match the accepted Apple Silicon route. The public readiness-seam test expects the accepted route on arm64 and rejects it on other architectures, while also rejecting changed browser versions, the Testing executable, self-import and the unverified reverse direction. Cross-compiling an Intel binary does not validate Intel browser lifecycle behavior.

The local validation host is Apple Silicon running macOS 27.0.1 with Swift 6.4 and the macOS 27 SDK. The shipped app and host can be cross-compiled for Intel here. A separately compiled minimal Intel program fails to execute with `Bad CPU type in executable`; Rosetta was not installed or enabled. The local `Testing.framework` contains arm64/arm64e slices and no Intel slice, so this toolchain cannot link or execute the Intel test runner. `bash test.sh` reports the tests executed on this arm64 host, not Intel tests.

There has been no Intel Mac launch, guided-migration, native-messaging, permission or recovery validation, and no macOS 14 runtime validation. Universal slice inspection and strict ad-hoc signature verification establish packaging integrity, not those runtime outcomes. The accepted automatic route retains its separately recorded Apple Silicon evidence in [connected-verification.md](connected-verification.md). Other browser/version routes remain guided, and an Intel automatic route requires its own real end-to-end acceptance evidence.

Ad-hoc signing is not Developer ID signing or Apple notarization. macOS may require the user’s normal local-app approval flow. Do not describe the universal build as notarized or Intel-runtime verified.

The credential helper is built with Cargo for both Apple targets, combined with `lipo`, and ad-hoc signed before the app. `bridge-credentials` accepts a bounded local JSON request on stdin; passphrases never appear in process arguments. Its bundled architecture/signature checks do not establish Intel credential UI or browser import acceptance.
