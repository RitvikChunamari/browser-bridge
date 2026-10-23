# Native organization capture on macOS

`try await NativeBrowserCapture.capture(browser: .arc)` returns a `Snapshot`; `.safari` is also supported. `portableCapture(browser:)` returns the existing `PortableCapture` document for JSON encoding and attachment in the app. These functions are main-actor isolated. Other browsers reject this route; use their profile reader or connector.

The app must explain that capture reads the running application's exposed windows, potentially across profiles. The user must confirm the intended source, close private Safari windows, and review the captured data before attaching it. Arc incognito windows are excluded. This adapter does not start or quit browsers, write browser stores, create native destination organization, install a helper, or bypass Automation consent.

## Contract v1

The script sends JSON `{schema:1,browser,version,windows}`. Arc windows contain Spaces (`id`, `name`, tabs), each tab contains `id`, `title`, `url`, `location`. The installed Arc vendor dictionary describes `topApp`, `pinned` and `unpinned` locations. `topApp` maps to the portable Essential flag plus pin; `pinned` maps to pin. Stable Arc tab IDs deduplicate mirrored Favorites/windows. Safari windows contain indexed ordinary tabs only; pin and Tab Group state is unknown and never invented. Original window identity and unknown JSON fields remain in the archival observation.

`Snapshot.nativeOrganization` is optional for backward compatibility. It contains `schema`, `adapter`, `browserVersion`, and `rawJSON`. Apply engines must treat raw JSON as archival data, not a native write instruction. Adapter v1 records the observed vendor version; it does not certify arbitrary future vendor releases. The script returns data through `JSON.stringify`; titles and URLs are never interpolated into executable code.

On macOS the implementation executes fixed JavaScript for Automation through OSAKit in process. Include `NSAppleEventsUsageDescription` in the containing app's Info.plist. Hardened-runtime distributions should configure the Apple Events automation entitlement according to their signing setup. OS prompts remain interactive. Denial/cancellation/error messages explain retry without force-quitting or modifying the browser. Task cancellation is checked before and after the synchronous OSA call; it does not dismiss an outstanding OS consent prompt.

## Zen organization recovery

When the newest readable generic Firefox session lacks spaces/folders, the reader supplements it from `zen-sessions.jsonlz4`. Tabs match only by stable `zenSyncId`/legacy `zenPinnedId`, never by URL. Live URL/title is retained; Zen pin/Essential/container/workspace/folder metadata is retained. Persistent pins absent from the live session are preserved with a freshness warning. Existing richly organized newest sessions keep precedence. A metadata-only Zen session is recognized. Unknown session state remains in profile backups; no native destination writer is implemented.

## Verification and limits

Tests first exposed missing native API/metadata, then exposed lost Zen metadata with a newer generic session. Synthetic capture tests cover quoted URLs, multiline titles, native location mapping, snapshot encode/decode, optional old-schema metadata, portable supplementation, unsupported schema/browser rejection, and stable-tab Zen merge. A compilation-only OSAKit test compiles both JXA programs without executing them or reading browser data. `swift test` builds the Mac app and CLIs as well as the test bundle.

Actual Arc/Safari Automation prompts, runtime vendor dictionary resolution, capture results, native destination creation and browser restart persistence have **not** been exercised. No personal profile migration was run. Use an isolated synthetic browser workspace and CUA for subsequent runtime verification; shell automation is not a substitute for that check. Dia proprietary Favorites/Spaces writes remain unsupported rather than inferred from ordinary Chromium APIs.

Primary references: [Zen session implementation](https://github.com/zen-browser/desktop/blob/dev/src/zen/common/modules/ZenSessionStore.mjs), [Zen Essentials implementation](https://github.com/zen-browser/desktop/blob/dev/src/zen/tabs/ZenPinnedTabManager.mjs), [Apple Automation consent](https://support.apple.com/en-hk/guide/mac-help/mchl108e1718/mac), installed Arc dictionary `/Applications/Arc.app/Contents/Resources/Arc.sdef`, installed Safari dictionary `/Applications/Safari.app/Contents/Resources/Safari.sdef` (read-only definition inspection).

Metadata-only Zen files do not hide a live session; an explicitly empty generic session still keeps precedence over older tab sessions. Synthetic positional fallback IDs are never used for cross-file matching, preventing unrelated tabs with the same URL or position from acquiring the wrong native identity.

Observed validation: `swift test --filter 'NativeOrganizationTests|ZenOrganizationRecoveryTests|NativeScriptCompilationTests'` passed the initial six tests; final `swift test` passed 32 tests across seven suites after the additional metadata-only and empty-session coverage. `git diff --check` passed. Swift 6.4's default build engine intermittently failed to resolve the existing TestingMacros plugin during intermediate runs; an attempted deprecated native-engine run also lacked Testing module search paths. The final ordinary SwiftPM build/test completed successfully. These are build-tool observations, not browser-runtime verification.
