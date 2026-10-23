# macOS trusted distribution

The Gatekeeper “Apple could not verify” warning indicates that the downloaded app lacks Apple's trusted distribution verification. It does not establish that malware was found. Existing ad-hoc builds are developer previews, not notarized releases.

`build.sh` now enables hardened runtime for the universal app and both helpers. The app receives only the Apple Events entitlement needed for optional Arc/Safari capture. Helpers receive no exception entitlements. No debugger, unsigned executable memory, JIT, or library validation exception is added. Runtime/browser behavior after this change still needs checking before release.

## Required owner setup

An Apple Developer Program account holder must obtain a **Developer ID Application** certificate and install its private key in the local Keychain. No valid signing identity was installed on the development Mac at the time of this change. Do not paste certificates, private keys, passwords or authentication codes into chat or source files.

Store notarization credentials interactively in Keychain using Apple's `xcrun notarytool store-credentials` command. Then configure only the certificate display name and Keychain profile name:

```sh
export BRIDGE_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export BRIDGE_NOTARY_PROFILE='browser-bridge-notary'
bash scripts/release-macos.sh
```

This builds and signs nested helpers before the app, uses secure timestamps and hardened runtime, submits the archive to Apple, requires an explicit Accepted status, staples and validates the ticket, verifies signatures, and requires Gatekeeper assessment to pass before creating `outputs/Browser-Bridge-macOS-universal-notarized.zip` and its SHA-256 file. Failed attempts produce no new trusted release archive. Only that successful artifact belongs in a notarized public Mac release.

Without the configured identity, `bash build.sh` remains an explicitly labeled ad-hoc developer build. It cannot remove Gatekeeper warnings. Do not disable Gatekeeper or remove quarantine as a distribution fix.

Notarization is a distribution check, not a guarantee of complete application security. Browser migration, backup, credential cleanup and platform acceptance tests remain separate requirements.

References: [Apple Developer ID](https://developer.apple.com/developer-id/), [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [hardened runtime](https://help.apple.com/xcode/mac/current/en.lproj/devf87a2ac8f.html).
