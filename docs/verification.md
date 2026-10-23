# Verification boundary

Automated fixtures cover standard discovery paths for all eleven browsers, Chromium bookmarks/history conversion, Safari plist/history conversion, Firefox/Zen session formats, Mozilla compression, mirrored-window deduplication, private checksum backups, safe destination paths, helper manifest selection, portable capture parsing and Netscape HTML nesting.

Importer/capture seam tests cover repeat imports, batch continuation, native group reuse, failed-removal journaling, interrupted-tree preservation, scheme filtering, conservative history rollback and opt-in capture limits.

Isolated Chromium integration exercises real extension APIs and rendered helper UI. Firefox 154.0.1 smoke tests use a disposable profile and local fixture pages: both manifest/background variants load; real capture, bookmark/pin/group/history APIs, repeat imports and conservative rollback pass. A new Firefox profile must finish bookmark initialization; immediate startup can intermittently reject a child folder. The helper now names the recovery step and preserves partial trees. Optional-permission prompts are not covered by that smoke harness.

Native SwiftUI overview/support/navigation and the new mark are visually inspected. Desktop/narrow helper layouts, keyboard focus, light/dark appearance and overflow are checked during integration.

No actual user data has been migrated. Vendor-specific Helium/Arc/Dia/Brave/Safari/Edge/Opera/Vivaldi acceptance is not established by Chromium-family fixtures. Safari manual import remains unverified. Native destination spaces/Favorites, authenticated cookies and incompatible extension settings are not claimed.

Release 0.2.0: 15 Swift tests and 11 JavaScript tests pass. Final release build and ad-hoc signature verification pass. Both review axes completed; Safari label findings were corrected and rereviewed.
