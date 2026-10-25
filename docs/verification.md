# Verification boundary

Automated fixtures cover standard discovery paths for all eleven browsers, Chromium bookmarks/history conversion, Safari plist/history conversion, Firefox/Zen session formats, Mozilla compression, mirrored-window deduplication, private checksum backups, safe destination paths, helper manifest selection, portable capture parsing and Netscape HTML nesting.

Importer/capture seam tests cover repeat imports, batch continuation, native group reuse, failed-removal journaling, interrupted-tree preservation, scheme filtering, conservative history rollback and opt-in capture limits.

Isolated Chromium integration exercises real extension APIs and rendered helper UI. Firefox 154.0.1 smoke tests use a disposable profile and local fixture pages: both manifest/background variants load; real capture, bookmark/pin/group/history APIs, repeat imports and conservative rollback pass. A new Firefox profile must finish bookmark initialization; immediate startup can intermittently reject a child folder. The helper now names the recovery step and preserves partial trees. Optional-permission prompts are not covered by that smoke harness.

Native SwiftUI overview/support/navigation and the new mark are visually inspected. Desktop/narrow helper layouts, keyboard focus, light/dark appearance and overflow are checked during integration.

No actual user data has been migrated. Vendor-specific Helium/Arc/Dia/Brave/Safari/Edge/Opera/Vivaldi acceptance is not established by Chromium-family fixtures. Safari manual import remains unverified. Native destination spaces/Favorites, authenticated cookies and incompatible extension settings are not claimed.

Release 0.2.0: 15 Swift tests and 11 JavaScript tests pass. Final release build and ad-hoc signature verification pass. Both review axes completed; Safari label findings were corrected and rereviewed.

## Connected profile slice (local, before route acceptance)

The native connector’s public store seam has 2 synthetic behavior tests: pairing, durable targeted command/result recovery, consumed-code rejection, wrong-browser/profile/secret rejection, disconnect revocation and oversized-command failure. The first test was observed red because `ConnectorStore` was absent, then green after implementation. The complete suite passes 17 Swift tests and 11 existing helper tests. These are not vendor end-to-end acceptance evidence.

The packaged app builds and passes strict ad-hoc signature verification with its native host included. In an isolated Chrome for Testing profile, the unpacked connector loads with its stable extension ID, its pairing form returns an actionable missing-host error, and its 380px light/dark layouts render without horizontal overflow. Popup screenshots are private QA artifacts under `work/connector-ui/`. Native Connections UI compiles; rendered native setup/readiness inspection and actual native-host round trips remain acceptance work for the integration run. No real user profile, native-host registration or global host manifest was modified by these synthetic/UI checks.

## Coordinated transfer slice

The public transfer seam adds one synthetic complete-flow test: live command/result exchange, normal-close/reopen ordering, backup before apply, retained redacted receipt, and custom Chromium global `Local State` preservation. The initial coordinator test was red while the module was absent. A second red observation showed custom user-data directory metadata was omitted, followed by the scoped backup-context fix. The complete local suite passes 18 Swift tests and 12 helper tests. A helper seam test verifies nested bookmark paths and pin states through destination reads, and catches post-import edits even when the import journal says complete.

Production routes remain disabled until exact browser/version full lifecycle acceptance is recorded. The local `transfer-validate` command requires an explicit disposable root and cannot enable shipping readiness. The native Transfer surface compiles; desktop rendering and actual quit/reopen lifecycle checks remain integration acceptance work. No user profiles were used in these synthetic tests.

## Recovery slice

The complete synthetic seam now includes paused-after-backup recovery with a new coordinator, no repeated capture or import, checksum-change rejection before apply, a retained redacted receipt, explicit rollback acknowledgement, and rollback after the source connection is removed. The store seam also distinguishes cancellation before delivery from an already claimed operation. Connected-helper tests recover a bookmark creation and a tab creation interrupted before their journal checkpoint without duplicating the tree/tab. The recovery tracer was observed red with `resume` absent, then green. The local suite passes 20 Swift tests and 14 helper tests.

Native recovery actions compile; actual route acceptance and rendered native UI inspection are recorded separately by the integration run. Pauses caused by temporary/disabled connectors, browser first-run UI, unsaved-work prompts and ambiguous restarted tabs are intentional limits, not success states. The typed shipping acceptance registry defaults empty until exact committed lifecycle evidence is available.

## Recovery review regressions

The public recovery seam reproduces two reviewed races: an import completes after timeout but before cancellation; and a verifier remains pending when Resume is selected. The first was observed red with a cancelled receipt despite completed effects. Cancellation now atomically rejects missing, completed or claimed jobs and requires the receipt’s active phase/connection/package. The second was observed red with a replacement job ID orphaning the pending verifier. Resume now retains that pending job; a fresh verification is queued only after the previous result is acknowledged. An enqueue conflict restores the receipt’s prior operation association. The same regression checks late-result recovery, queue-conflict association and a subsequent fresh successful observation. Full local verification passes 21 Swift tests and 14 helper tests.

## macOS browser identity and step cancellation

Actual Chrome → Brave lifecycle testing observed a macOS code-signing clone as the native host’s parent executable, so parsing a raw `.app/` process path rejected the legitimate reopened browser. The host now uses macOS running-application identity, checks the supported bundle identifier and canonical bundle/executable agreement, and retains the strict connector-origin allowlist. The integration run confirmed a fresh Brave heartbeat and a resumed cross-browser transfer with independent verification (11 bookmarks, 2 tabs, 1 group and 3 history URLs; no mismatches).

A further public recovery regression was observed red when cancelling an undelivered verifier after import made prior effects ineligible for rollback. Cancelling later steps now preserves the paused receipt and its recovery phase; only a source capture before any import is terminally cancelled. The local suite passes 22 Swift tests and 14 helper tests.

## Additive destination baseline

A new complete-seam regression was observed red: the destination’s original HTTP(S) tab disappeared after reopening, yet the earlier pipeline applied and reported success. Transfer now captures a durable destination baseline before quit, requests Chromium’s previous-session restore, and independently checks existing tab/pin/group-name and bookmark-path multisets before apply and after import. Missing original items pause before further writes. The regression passes through missing-session pause, restored-session Resume, and one additive apply without recapturing the source. Separate persisted capture/check phases retain the correct pending command across interruptions. The local suite passes 23 Swift tests and 14 helper tests; actual destination-baseline retention remains a release acceptance gate until the real-browser integration run records it.

## v0.4.0 — 1-Click Direct Profile Migration, Multi-Space Zen → Dia, Full History Engine & Native macOS System Settings UI

In v0.4.0, the verification suite expands to **61 Swift tests across 8 suites** (`swift test`) and **21 Node.js tests** (`node --test Tests/Importer/*.test.mjs Tests/Sessions/*.test.mjs Tests/Website/metadata.test.mjs`):

1. **1-Click Direct Profile Migrator (`OneClickMigratorTests`)**:
   - Verifies direct Chromium (`Bookmarks` JSON) and Firefox/Zen (`places.sqlite`) injection, nested folder hierarchy preservation, `⭐ Essentials` propagation across every Dia space (`testOneClickDiaPreservesEssentialsInEverySpace`), multi-space mapping (`testOneClickMigratesMultiSpaceDirectToDiaAndRollback`), dynamic `Local State` (`last_used` / `Profile 9`) resolution (`testChromiumUserDataRootProfileResolution`), WAL/SHM journal backup and cleanup, and atomic 1-click rollback.
2. **Full Browsing History Migration (`HistoryMigrationTests`)**:
   - Verifies zero-lock safe reading (`PlacesReader.withSafeReadCopy` and `immutable=1` URI mode) on active locked SQLite databases (`testZeroLockReadingOnLiveActiveBrowser`).
   - Verifies complete 22-table Chromium v70 `History` schema initialization (`testChromiumHistoryCompleteSchemaInitialization`), lock tolerance (`sqlite3_busy_timeout(db, 5000)`), and Windows FileTime microsecond conversion (`testChromiumHistoryDirectWriteAndRead`, `testChromiumHistoryLockTolerance`).
   - Verifies Firefox/Zen `moz_places` and `moz_historyvisits` writing with reversed host indexing (`rev_host`), frecency scoring, and 12-char GUID generation (`testFirefoxRevHostAndFrecencyCalculation`, `testFirefoxHistoryDirectWriteAndRead`).
   - Verifies `SQLITE_TRANSIENT` string memory safety with Unicode and special characters (`testStringMemorySafetyAndSpecialCharacters`), history-only migration isolation (`testHistoryOnlyMigrationPreservesExistingBookmarksAndSessions`), CLI `--dry-run` / `--no-history` flags (`testOneClickCLIDryRun`, `testOneClickCLIHistoryFlags`), and full rollback of newly created history files (`testRollbackDeletesNewlyCreatedHistoryFiles`).
3. **Native macOS HIG & Website Verification**:
   - Verified zero `slop` errors via `impeccable detect --json desktop/app/ui/style.css website/style.css`.
   - Visually verified the compileduniversal/release `Browser Bridge.app` macOS System Settings (`FormStyle.grouped`) interface on macOS.
