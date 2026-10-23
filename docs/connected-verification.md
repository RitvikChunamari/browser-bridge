# Connected release verification

## Website

The dark static product site was inspected at desktop and mobile sizes. Fourteen visitor checks cover the labeled simulation, Safari and same-browser limits, shared route/filter state, keyboard/skip navigation, reduced motion, all eleven entries, runtime errors and horizontal overflow at 320, 390, 768 and 1440 pixels. External release/source/security/license links returned HTTP 200. The GitHub Pages workflow completed successfully and the deployed simulation was exercised at https://ritvikchunamari.github.io/browser-bridge/.

## Real native messaging — transport and setup

An official Google Chrome 156.0.8078.48 build, verified with strict code signing, was run with two disposable profiles. Both profiles installed the unpacked connector through Chrome's actual extensions interface and paired through the origin-restricted native host. No personal browser profile was used. Optional history/group permission was exercised through Chrome's actual prompt in the disposable destination.

A local fixture import created two source tabs, including one pin, and nested bookmarks. Native capture returned the two HTTP fixture tabs plus the internal connector page; the latter remains nonportable. A separate native destination import produced two tabs, five bookmarks and one history URL. A native verification request observed the two tabs and five bookmarks with no mismatch. These are real transport/API checks. The subsequent lifecycle and cross-vendor acceptance checks are recorded below.

Migration payloads, connection secrets, synthetic profile files, raw native receipts and screenshots of test profiles remain under ignored local work storage, not in the public source or website artifact. Automatic route enablement additionally requires the exact lifecycle gate recorded below.

## Coordinated lifecycle checks — 23 October 2026

Disposable profiles in official, signature-verified Google Chrome 156.0.8078.48 and Brave 156.1.98.60 exercised capture, normal browser quit, checksummed package creation, exact destination reopening, native messaging, import and independent verification. A Chrome-to-Chrome recovery completed with ten bookmarks and four tabs. A Chrome-to-Brave recovery completed with eleven bookmarks, two tabs, one group and three history URLs, with no verification mismatches.

The cross-vendor check exposed macOS executable cloning during browser reopening. Native-host identity now uses the operating system's running-application bundle and executable identity with strict known-browser matching. The corrected host reconnected and the paused transfer resumed successfully.

Recovery checks alone did not establish uninterrupted automatic-route acceptance. A fresh run also had to preserve destination state created outside Browser Bridge's owned import tree. The implementation captures a checksummed destination baseline and checks its portable tabs, pin/group state and bookmark paths both before and after import. Synthetic tests cover destination-loss detection and recovery; they do not replace this gate.

## Accepted automatic route — 23 October 2026

A fresh, uninterrupted run in disposable official browser profiles completed **Google Chrome 156.0.8078.48 → Brave 156.1.98.60** through capture, normal quit, checksummed source/destination backup, exact destination reopening with previous-session restoration, additive import and independent verification. The imported intent and observed result agreed: eleven bookmark links and two tabs, including one exposed tab group, plus three history URLs; no mismatches were reported.

The destination baseline independently contained twelve bookmark links and three HTTP(S) tabs, including a separately created unpinned tab and bookmark outside the helper-owned import tree. Both pre-apply and post-apply preservation checks reported zero missing tabs/pin/group states and zero missing bookmarks. Raw payloads, receipts, paths and screenshots remain private ignored QA artifacts; only these verification facts are published.

The shipping immutable readiness registry therefore accepts only that exact direction, browser versions and observed executable names (`Google Chrome` and `Brave Browser`). Chrome for Testing, other versions, the reverse direction, same-browser routes and all other vendor pairs remain unverified for automatic Transfer and use guided fallbacks. The earlier Chrome-to-Chrome recovery check does not enable its automatic route. Browser updates require new lifecycle acceptance rather than silently inheriting this result.

A public readiness-seam regression was observed red while the registry was empty, then green after this evidence-backed entry. It also rejects version changes, the Testing executable, self-import and the unverified reverse direction.

The fresh accepted transfer was then rolled back through its durable receipt. The helper reported `rolledBack`, and an independent native capture still contained the separately created destination baseline tab and bookmark. This checks preservation outside helper-owned roots during undo; it does not imply that edited helper-owned bookmarks or imported history can always be restored or removed. Rollback's disclosed retention rules still apply.

## Release checks and remaining limits

The integration build passes 24 Swift tests and 14 JavaScript helper tests; the website passes 16 visitor checks with inspected desktop/mobile screenshots. Production app compilation and strict ad-hoc code-signature verification pass. Native SwiftUI visual/keyboard inspection could not finish because the computer-use inspection service crashed while traversing the running app; Browser Bridge itself remained running. The coordinated pipeline was exercised through its local CLI with real disposable browsers. This is a beta, not a claim of exhaustive native UI or fresh-Mac validation. The app is not Apple-notarized, and local connector setup is required. No paid signing or store enrollment was used.
