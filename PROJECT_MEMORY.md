# Browser Bridge Project Memory

## Project Purpose & Architecture
Browser Bridge provides seamless, 1-click browser-to-browser migration for tabs, bookmarks, tab groups, and spaces across modern macOS browsers (Chrome, Brave, Arc, Zen, Dia, Helium, Firefox, Safari, Edge, Opera, Vivaldi).
It replaces multi-step manual pairing architectures (developer mode flags, unpacked extensions, 10-minute pairing codes, and manual JSON import/export) with a direct, local zero-extension migration engine.

### Core Architecture
- **`BridgeCore`**: Standalone Swift framework providing `OneClickMigrator`, SQLite/Netscape HTML parsers and generators, backup journals, and rollback managers.
- **`BridgeMigrateCLI` (`bridge-migrate`)**: CLI executable for positional and flag-based terminal migrations (`swift run bridge-migrate <source> <dest>`).
- **`BrowserBridge.app`**: Native SwiftUI desktop application (`Sources/BrowserBridge/App.swift`, `Sources/BrowserBridge/CredentialView.swift`) built around authentic macOS Human Interface Guidelines (`System Settings` inset grouped rows, `Color(nsColor: .windowBackgroundColor)` & `Color(nsColor: .controlBackgroundColor)`, `1px` `separatorColor` dividers, `24×24pt` rounded-rect icon badges, native AppKit `.toggleStyle(.switch)` controls, `.buttonStyle(.borderedProminent)` CTAs, `.monospacedDigit()` tabular counts, and instant rollback).
- **Desktop Web/Tauri UI (`desktop/app/ui/`)**: Vanilla ES module frontend mirroring macOS dark-mode system tokens (`#1e1e1e` window background, `#28282b` grouped surfaces, `1px` `rgba(255,255,255,0.09)` borders, `7px` button radius, `10px` group radius, `tabular-nums`, and `prefers-reduced-motion` compliance) with 1-click workspace, progress bar, success cards, and accessible advanced settings.
- **Showcase Website (`website/`)**: High-performance semantic HTML/CSS site styled with restrained Apple dark editorial tokens (`#000000` canvas, `#141416` / `#1d1d1f` surfaces, `#f5f5f7` primary ink, `#86868b` secondary ink, solid `#0071e3` CTA buttons, and `1px solid rgba(255,255,255,0.09)` borders) featuring a "Before (Traditional multi-step manual) vs After (Browser Bridge 1-Click)" comparison section.

## Key Technologies & Dependencies
- **Backend / CLI**: Swift 6.0, CSQLite system library, Foundation, CryptoKit, AppKit.
- **Frontend / Website**: HTML5, Vanilla CSS3 (glassmorphic variables, responsive design, spring physics), modern ES modules.
- **Testing**: Swift Testing framework (`import Testing`), Node test runner (`node --test`), Playwright for headless browser journey verification.

## Conventions & Technical Decisions
- **Zero-Extension Migration**: Directly injects bookmarks into Chromium `Bookmarks` JSON and Firefox `places.sqlite` / Netscape HTML bookmarks.
- **Safety Pre-flight & Backups**: Automatically backs up destination profile files (including `places.sqlite-wal` and `places.sqlite-shm`) to `~/.browser-bridge/backups/<timestamp>` before modifications.
- **Atomic Rollbacks**: Every migration writes a receipt to `~/.browser-bridge/receipts/<id>.json`. Rollbacks restore backups and remove injected bookmark folders cleanly.
- **Firefox Places Hierarchy**: Root items in Firefox use parent ID 1 (places root), unlike Chromium's parent 0. The tree builder detects non-zero parents and synthesizes proper hierarchies.
- **Firefox SQLite Schema**: Dynamically checks `PRAGMA table_info(moz_bookmarks)` for `guid TEXT NOT NULL UNIQUE` and generates valid 12-character alphanumeric GUIDs.
- **Hierarchical Folders & Essentials Preservation**:
  - `⭐ Essentials / Pinned Favorites`: In Zen Browser, Essentials are global pinned favorites that appear across all workspaces. In Dia Browser, these are propagated to every Dia space (profile) both as direct bookmark buttons on the bookmarks bar and inside both `"⭐ Essentials"` and `"⭐ Pinned Favorites"` folders.
  - **Zen to Dia Multi-Space Architecture & Live Automation**:
    - Arc/Dia spaces are backed by individual Chromium profiles in `~/Library/Application Support/Dia/User Data`.
    - Profile Matching: Existing active/starter profiles (e.g. `Profile 9` with name `"Profile"` or `last_used`) are detected and mapped to primary space `Personal`, preserving user state and defaults without orphaned profiles.
    - Native AppleScript automation suite (`Dia.sdef` via `ArcCore.framework`): A Dia `profile` represents a vertical sidebar space (`• • • • •`).
    - Pinned tabs appear as compact grid tiles in the top tray of each space's sidebar, toggled via menu item `"Pin"` of menu 1 of menu bar item `"Tabs"` and reflected in AppleScript as `isPinned of tab`.
    - Dia Pinned Tab Lifecycle: In Dia, calling `close t` on a pinned tab is ignored. To delete or replace duplicate pinned tabs, the tab must be focused, unpinned via GUI scripting (`menu item "Unpin"`), and then closed via `close t`.
    - Canonical Key Deduplication (`canonicalKeyFor(url:title:)`): Normalizes domain drift and login redirects (e.g., `mail.google.com` vs `accounts.google.com`, `calendar.google.com` vs `workspace.google.com/calendar`, `login.microsoftonline.com` vs `copilot.com` / `canvas.colorado.edu`) to ensure all 12 Essentials and space pins remain idempotent without duplicate tiles.
    - CLI Launch Isolation: Dia/Chromium CLI arguments (`open -b company.thebrowser.dia <urls>`) route exclusively to the frontmost window/profile. `launchDestination` passes empty CLI URLs for Dia to prevent clobbering profile isolation.
    - `syncDiaLiveSpaces(snapshot:)` automates live Dia instances: focuses each profile window explicitly, deduplicates existing pinned tabs, pins all 12 Essentials into EVERY Dia profile so essentials remain identical across every space, pins each space's pinned tabs as compact sidebar tiles, and populates open tabs per space.
    - Eliminates any requirement for the user to manually create or pick a destination profile in Dia.
  - Spaces / Workspaces: Each space maintains its own `📌 Pinned Tabs`, recursive nested subfolders with their tabs, and unfiled `Open Tabs`.
  - Nested Folders: Folders preserve their exact hierarchy (`parentID` nesting) and contain their assigned tabs (`tab.folderID == folder.id`) in source browser order.
  - Tab Launch Prioritization: Post-migration browser launch activates the destination browser via `NSWorkspace` and launches top essential and pinned tabs immediately.
- **History Migration Engine**:
  - **Zero-Lock Safe Read (`PlacesReader.withSafeReadCopy`)**: Active browsers (Chromium/Dia and Firefox/Zen) hold exclusive SQLite file locks or open WAL journals on `History` and `places.sqlite`. `withSafeReadCopy` attempts direct read first; if locked (`SQLITE_BUSY`/`SQLITE_LOCKED`), it copies the database along with its `-wal`, `-shm`, and `-journal` sidecar files into an isolated sandbox (`~/.temporaryDirectory/bridge_sqlite_reader_*`) for an unlocked, non-blocking read.
  - **Dynamic Profile & Subprofile Resolution**: Chromium reader dynamically discovers profile history across `Default/History`, `Local State`'s `last_used`, and `Profile */History` (supporting Dia's multi-profile spaces architecture like `Profile 9`).
  - **Chromium / Dia History Schema & Lock Tolerance (`History` SQLite)**:
    - Tables: `meta`, `urls`, `visits`, `visit_source`, `keyword_search_terms`, `downloads`, `downloads_slices`, `downloads_url_chains`, `segments`, `segment_usage`, `content_annotations`, `context_annotations`, `clusters`, `clusters_and_visits`, `cluster_keywords`, `cluster_visit_duplicates`, `visited_links`, `history_sync_metadata`, `journeys`, `journey_history_entries`, `journey_continuation_queries`, `journey_sync_metadata`.
    - Complete Schema Requirement: Chromium/Dia razes (`db_.Raze()`) any `History` database on startup if `meta` has `version == 70` but other version 70 tables (such as `segments`, `downloads`, or `keyword_search_terms`) are missing, leaving 32KB empty databases with zero tables (`no such table: urls`). `OneClickMigrator` initializes the complete Chromium v70 table suite and copies sibling profile templates (`Profile 9/History`, `Default/History`) when creating new profiles.
    - Busy Timeout & Lock Tolerance: Sets `sqlite3_busy_timeout(db, 5000)` and `PRAGMA busy_timeout = 5000;` immediately after `sqlite3_open`, with retried connection and immediate transaction backoff loops.
    - Graceful Quit Hardening: `gracefullyQuitRunning` falls back to `app.forceTerminate()` if the browser application ignores normal quit requests or blocks on modal prompts, ensuring SQLite file locks are completely released prior to migration writes.
    - Multi-Profile Synchronization: Every profile directory in Chromium/Dia (`Profile 9`, `Profile 1`, `Profile 2`, `Profile 3`, `Profile 4`) and Arc (`Default`, `Profile 1`) receives full history synchronization.
    - Timestamp Conversion: Chrome stores timestamps as Windows File Time in microseconds UTC (`(unixMs + 11644473600000) * 1000`).
    - URL Filtering: Excludes browser-internal and non-routable schemes (`chrome:`, `dia:`, `about:`, `place:`, `chrome-extension:`).
  - **Firefox / Zen History Schema (`places.sqlite` SQLite)**:
    - Tables: `moz_places` (`url`, `title`, `rev_host`, `visit_count`, `hidden`, `typed`, `frecency`, `last_visit_date`, `guid`), `moz_historyvisits` (`place_id`, `visit_date`, `visit_type`).
    - Timestamp Conversion: Firefox stores timestamps in Unix epoch microseconds (`unixMs * 1000`).
  - **Atomic Backup & Rollback**:
    - During pre-flight backup, all history files (`History`, `History-journal`, `History-wal`, `History-shm`, and `<profile>_History*`) are copied to the timestamped backup folder.
    - Rollback restores original pre-existing history files and cleans up any newly created history databases.
  - **Default Setting & Flags**:
    - History transfer is enabled by default across CLI (`bridge-migrate`) and GUI (`BrowserBridge.app`).
    - Users can disable via `--no-history` CLI flag or GUI settings toggle.

- **Memory Safety & String Lifetime (`PlacesReader.SQLITE_TRANSIENT`)**: All dynamic Swift strings (`NSString.utf8String`) bound to SQLite statements use `PlacesReader.SQLITE_TRANSIENT` (`unsafeBitCast(-1, to: sqlite3_destructor_type.self)`) preventing ARC deallocation before statement execution.
- **Firefox Host Indexing (`rev_host`)**: `writeFirefoxHistory` generates `rev_host` (`String(host.reversed()) + "."`), enabling Zen and Firefox omnibox autocomplete indexes (`moz_places_hostindex`).
- **Zero-Lock URI Mode**: `PlacesReader.rows` opens databases using `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` with `file:\(path)?immutable=1` bypassing locks and WAL recovery on active browser profiles.
- **History-Only Migration Isolation**: In `OneClickMigrator.migrate`, when migrating history only (`options.bookmarks == false && options.tabs == false && options.groups == false`), bookmark, tab, and session injection methods (`migrateToChromium`, `migrateToDiaSpaces`, `migrateToFirefox`, `migrateToSafari`) are bypassed entirely, preventing accidental clobbering of bookmarks or active sessions.
- **Dia Session Preservation**: In `migrateToDiaSpaces`, existing active Dia profiles (`isExistingActiveDiaProfile`) preserve their `Sessions` folder intact, retaining active spaces and tabs across migrations.
- **Dynamic Chromium & Dia Profile Resolution**: `resolvePrimaryChromiumProfile` inspects `Local State` (`profile.last_used`) and candidate directories (`Default`, `Profile *`), preventing hardcoded `Default/` failures (SQLite error 14) on browsers like Dia where primary workspaces reside under `Profile 9`.
- **Ephemeral Test Receipts**: `OneClickMigrator.receiptDirectoryOverride` routes test receipts to an ephemeral sandbox whenever test suites run or temporary directories are detected, preventing pollution of `~/Library/Application Support/Browser Bridge/OneClickTransfers`.

## Important Verification Commands
- `swift test`: Run full Swift test suite (61 tests in 8 suites) with Swift Testing macros.
- `swift run bridge-migrate --dry-run zen dia`: Test dry-run migration simulation from Zen to Dia (verifying history count detection).
- `swift run bridge-migrate --dry-run --no-history zen dia`: Test dry-run migration with history disabled.
- `swift run bridge-migrate zen dia`: Execute 1-click live migration from Zen to Dia.
- `swift run bridge-inspect zen <profile-path> -v`: Inspect full inventory of tabs, spaces, folders, essentials, pins, and history.
- `swift run bridge-migrate --sync-dia`: Synchronize Zen spaces, pinned sidebar tiles, and open tabs into the active Dia instance.
- `cp .build/out/Products/Release/BrowserBridge "Browser Bridge.app/Contents/MacOS/BrowserBridge" && touch "Browser Bridge.app"`: Update macOS desktop app bundle with latest compiled release binary.
- `node --test Tests/Importer/*.test.mjs Tests/Sessions/*.test.mjs Tests/Website/metadata.test.mjs`: Run Node test suite (21 tests).
- `node Tests/Website/visitor-checks.js`: Run Playwright website assertion suite (16 checks).
