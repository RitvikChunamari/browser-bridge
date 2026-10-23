# Cross-platform browser migration feasibility

Research snapshot: 2026-10-23. Facts and recommendations only; no product source changes. Existing exact Chrome → Brave macOS route was reported verified by the parent task; this note does not generalize that result to other routes or operating systems.

## Capability facts and classification

| Surface | Established facts | Classification / next step |
|---|---|---|
| Chromium standard tabs, pins, groups, bookmarks | Official tabs API creates/reorders tabs; tabGroups modifies ordinary groups, bookmarks preserves nested folder trees. APIs require relevant extension permissions. | Existing implementation plus per-vendor/version verification. Grouping is not nested folders, native Spaces, Essentials or Favorites. |
| Firefox standard tabs/groups | Mozilla documents tabs.group/ungroup in Firefox 138 and tabGroups in 139. | Existing helper has Firefox manifest now; gate capabilities/version and test actual Firefox/Zen builds. Do not call all Firefox groups unsupported. |
| Zen Essentials/workspaces | Official source stores custom zenEssential/zenWorkspace state and uses privileged browser internals for Essentials; repository implements ZenSessionStore for internal browser use. | Dedicated native mapping missing. No documented public third-party workspace/Essentials API was established in this investigation. A version-bound offline adapter or upstream API contribution is plausible; generic tabs.pin is only approximation. |
| Arc sidebar | Installed Arc.sdef exposes spaces (read-only id/title, tabs, focus) and tab location values topApp/pinned/unpinned. It exposes no folder class in the inspected dictionary. Official help describes Spaces and import-to-pinned-tab behavior. | A macOS AppleScript source adapter could improve extraction; not implemented/verified here. It is not evidence of full folder/space creation on Windows. Offline StorableSidebar parsing is a version-bound adapter requiring fixtures. |
| Dia Favorites/pinned groups | Official current changelog distinguishes Favorites, Arc-style pinned tabs and groups, and provides a Favorites keyboard shortcut. | Generic Chromium pin state cannot establish Favorites semantics. No documented public Favorites management API found in reviewed official material. Dedicated native adapter investigation needed; UI automation requires OS access and version tests. |
| Safari | Apple documents native import/export and app-packaged Safari extensions. Installed Safari.sdef exposes windows/tabs but no Tab Group class in inspected dictionary. | Existing adapter supports bookmarks/history profile reading and guided HTML only. Automation for ordinary tabs is an unimplemented macOS option; native Tab Group import remains uncertain. Extension distribution requires Apple's signing/distribution workflow; do not introduce paid enrollment automatically. |
| Windows/Linux host | Chrome and Firefox both document native messaging on Windows/Linux/macOS. Windows uses registry registration; Linux/macOS use filesystem manifests. | Public API exists. Platform discovery, installer, binary transport, lifecycle and tests are missing. Windows stdio binary mode matters. |
| Consent/setup | NativeMessaging permission and host allowlists are required; extension installation/activation is browser controlled. macOS Automation access requires the user to Allow. | Required user setup cannot honestly be promised as zero consent. After pairing, automate only supported operations and pause for blocked permissions/prompts. |

## Existing local implementation boundaries

`Package.swift` targets macOS 14; the app is SwiftUI/AppKit. `MacBrowserLifecycle.swift` imports AppKit and identifies `.app` bundles; it supports normal quit, timed wait and reopening the paired executable/profile. `BrowserCatalog.swift` lists macOS Library paths only. `ConnectorInstallation.swift` installs macOS manifests only. `BridgeHost/main.swift`, `ConnectorStore.swift` and `TransferCoordinator.swift` import Darwin; backup/coordinator use CryptoKit. Thus Windows/Linux is a substantial platform port, not a packaging toggle. Existing JS connector/capture/import engine is reusable across platforms subject to API differences. Current support text explicitly maps Zen Essentials to pins and spaces to bookmark trees; Arc sidebar and Vivaldi workspaces remain archive-only. Chromium offline tabs are not decoded, so live connector capture is required.

## Practical adapter strategy (recommendation, not a promise)

1. Keep the neutral capture/package schema and JS extension capture/apply engines. Implement a capability contract per browser/version/category, rather than assuming family membership proves compatibility.
2. Split the host into portable protocol/backup/journal logic and OS adapters for paths, process/profile identity, lifecycle, permissions, native-host registration and installation. Keep existing macOS route tests intact.
3. Add supported-source/supported-target matrices; verify each route through relaunch persistence and rollback, including grouped/pinned conflicts and nested-folder fallbacks. Retain exact native fields in the archive even when destination approximation is necessary.
4. Investigate native organization adapters separately: Zen versioned session schema; Arc macOS dictionary + sidebar schema; Dia vendor API/native import if available. Prefer official extension/native interfaces; gate any offline writer by exact schema/version, closed-browser consistency and reversible backups. Never write unknown proprietary stores blindly.
5. Start Windows/Linux with common Chromium/Firefox connectors and ordinary categories. Do not promise Safari on unsupported OSes or Arc/Dia availability on Linux. Verify vendor platform availability independently before shipping a platform matrix.
6. Offer guided steps for credentials, browser-required consent and unsupported native structures; receipts should distinguish transferred, approximated, archived and blocked. A seamless manager can coordinate the journey without claiming every category is automatically writable.

## Primary sources

- Chrome tabs: https://developer.chrome.com/docs/extensions/reference/api/tabs
- Chrome groups: https://developer.chrome.com/docs/extensions/reference/api/tabGroups
- Chrome bookmark tree: https://developer.chrome.com/docs/extensions/reference/api/bookmarks
- Mozilla group introduction and versions: https://blog.mozilla.org/addons/2025/04/30/webextensions-support-for-tab-groups/
- Mozilla groups: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabGroups
- Chrome native messaging, OS registration and binary transport: https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging
- Firefox native manifests: https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_manifests
- Zen privileged session implementation (moving dev branch): https://github.com/zen-browser/desktop/blob/dev/src/zen/common/modules/ZenSessionStore.mjs
- Zen Essentials implementation (moving dev branch): https://github.com/zen-browser/desktop/blob/dev/src/zen/tabs/ZenPinnedTabManager.mjs
- Zen workspace/container semantics: https://docs.zen-browser.app/user-manual/workspaces
- Arc Space semantics: https://resources.arc.net/hc/en-us/articles/19228064149143-Spaces-Distinct-Browsing-Areas
- Arc native importer: https://resources.arc.net/hc/en-us/articles/19335089616791-Import-Bookmarks-Logins-History-Extensions-from-Your-Previous-Browser
- Arc installed vendor dictionary inspected read-only: /Applications/Arc.app/Contents/Resources/Arc.sdef
- Dia current organization/features: https://www.diabrowser.com/changelog
- Safari native import: https://support.apple.com/guide/safari/import-bookmarks-and-passwords-ibrw1015/mac
- Safari extension distribution: https://developer.apple.com/documentation/safariservices/distributing-your-safari-web-extension
- Safari installed vendor dictionary inspected read-only: /Applications/Safari.app/Contents/Resources/Safari.sdef
- Apple Automation consent: https://support.apple.com/en-hk/guide/mac-help/mchl108e1718/mac

Absence of an API in the reviewed documentation is a research boundary, not proof that no private/vendor interface exists. No personal browsing records, credential values or profile contents were inspected for this note.

## Credentials and signed-in sessions: essential scope, separate pipeline

**Current evidence:** [Chrome Computer help](https://support.google.com/chrome/answer/13068232) now uses a passwords-and-passkeys heading and generic introduction. Its actual desktop procedures still describe password CSV import/export (url/username/password columns), not a documented desktop passkey-file exchange flow. Thus neither “all passkeys cannot move” nor “Chrome desktop exports transferable passkeys” is established by that page. [FIDO's credential exchange overview](https://fidoalliance.org/specifications-credential-exchange-specifications/) establishes a standard for password/passkey portability; standard existence does not prove each desktop browser/provider implements it. [Firefox official export](https://support.mozilla.org/en-US/kb/export-login-data-firefox) supports password CSV.

**Passwords recommendation:** a separate, explicit consent step invokes native browser/provider export and import. Keep OS/browser authentication interactive. Validate/normalize user-supplied CSV locally; do not log secrets, put them into ordinary snapshots or commit them to source. Use a transient owner-only workspace and remove it after destination confirmation; explain that file deletion is not guaranteed secure erasure on SSD/snapshots. Test entirely with invented credentials and a local test origin. Verify that destination saved entries can be used after restart, and separately test duplicate/error/cancel/cleanup paths. This is missing implementation, not absence of a password interchange format. Browser APIs here do not establish a general privileged password-vault read/write API.

**Passkeys recommendation:** discover actual credential provider, OS and version; prefer its official credential-exchange/provider flow where both sides support it. Preserve provider continuity where appropriate, or guide creation of an additional passkey on the relying party. Never label a password CSV as a passkey backup. Device-bound/security-key credentials require their authenticator rather than generic key extraction. Test provider exchange only when that specific desktop route is available; ordinary password success is not passkey success.

**Cookies recommendation:** cookie transfer is technically possible through permissioned extension APIs; it is currently missing implementation. [Chrome cookies API](https://developer.chrome.com/docs/extensions/reference/api/cookies) requires cookies plus host permissions and exposes partitionKey. [Mozilla cookies API](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/cookies) exposes partitionKey and firstPartyDomain, with store/container differences. Request access per selected sites where practical; enumerate only consented hosts. Retain secure/httpOnly/sameSite/domain/path/expiry/partition metadata; refuse incompatible container/partition mapping instead of flattening identities. Destination overwrites need before-state journaling and rollback that does not erase later unrelated changes. Raw encrypted cookie DB copying is not equivalent to using the live browser API, particularly across OS/browser crypto keys.

**Authentication boundary:** [Google's April 2026 DBSC announcement](https://blog.google/security/protecting-cookies-with-device-bound-session-credentials/) establishes Windows availability and device-bound non-exportable keys with rotating session cookies. A cookie successfully written/read in a destination does not prove the destination is authenticated; DBSC, expiry, server policy, missing non-cookie storage and other site logic may require sign-in again. Do not promise transfer of hardware-bound proofs. User-approved per-site checks may report observed signed-in state, with “not checked” separate from “sign-in required”; do not silently visit accounts or perform account actions. Synthetic checks should include ordinary HttpOnly cookie-backed local sessions, partitioned-cookie preservation, expiry, incompatible stores, rollback and a deliberately device-bound/re-auth simulation. Real-account survival remains explicitly user-assisted, site-specific verification.

**Platform priority from parent:** Windows 10 x64, Windows 11 x64/ARM64, Ubuntu 24.04 x64/ARM64, Debian/Fedora x64. These are targets, not currently verified support. NativeMessaging APIs exist on Windows/Linux, but browser availability, platform packaging and machine execution remain per-target validation work. A macOS-only test host cannot prove those targets. Install/extension consent, vault authentication and OS prompts remain necessary even when the manager automates discovery/capture/backup/apply/relaunch/report after setup.
