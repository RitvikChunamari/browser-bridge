# Contributing

Browser Bridge is MIT licensed. Contributions must preserve originals, state capability limits clearly and use free/local tooling.

1. Build with `./build.sh` on macOS with Apple Swift tools.
2. Run `./test.sh` with Node.js available. Tests use synthetic fixtures; never commit browser profiles, credentials, captured tabs, private URLs, screenshots of personal browsing or migration packages.
3. Add source adapters behind the neutral snapshot interface. Keep native-browser metadata separately when portable equivalents are approximations.
4. Test exported behavior and safe import/rollback at public interfaces. Declare actual-browser verification separately from fixtures and browser-family assumptions.
5. Use isolated browser profiles for integration checks. Run the interface, inspect relevant states and keyboard access, then describe what was verified in the change.

Open a small issue or pull request with the browser/version, data categories involved, a synthetic reproducer and expected behavior. Share only sanitized metadata. Changes that overwrite opaque browser databases or silently drop unsupported data will not be accepted.

New contributors can start with discovery paths, synthetic adapter fixtures, compatibility documentation or local accessibility fixes.
