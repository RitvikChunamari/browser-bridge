<p><img src="Assets/Brand/logo.svg" width="72" height="72" alt="Browser Bridge logo"></p>

# Browser Bridge

A free, MIT-licensed macOS manager for moving a portable browsing setup between **Helium, Arc, Zen, Dia, Chrome, Firefox, Brave, Safari, Edge, Opera and Vivaldi**.

Choose a source, choose a destination, inspect what transfers, and create a private migration package. Browser Bridge keeps originals intact and reports approximations, manual steps and unsupported categories. It uses SwiftUI and system libraries; the built app has no paid services, accounts, uploads or external runtime dependencies.

**Beta 0.3.0 · Apple Silicon · macOS 14+**. Profile adapters and public browser APIs are not a promise that every native feature transfers between every browser version. Read the support table before migrating.

## Connected Transfer

Connect each exact profile once using [local connector setup](docs/connector-setup.md), choose a backup folder, and acknowledge the normal browser quit. For accepted routes, **Transfer** captures live data, preserves a destination baseline, closes the selected browser apps normally, creates a checksummed backup, reopens the destination, imports and independently verifies the result. Paused receipts offer resume and conservative rollback.

The verified automatic route is **Google Chrome 156.0.8078.48 → Brave 156.1.98.60** on Apple Silicon macOS. Other versions and directions use guided packages. Verification covers portable bookmarks, tabs/pins, exposed groups and selected history; native spaces and authenticated sessions are not recreated. See [actual verification evidence](docs/connected-verification.md).

[Product website](https://ritvikchunamari.github.io/browser-bridge/). Windows, iOS, Android and Linux: coming soon, without announced dates.

## Guided package quick start

1. Open `Browser Bridge.app`. Choose the source and destination browser/profile.
2. For Chromium tabs/pins/groups, click **Save capture helper…**, load it in the source browser, and save its local JSON capture. Attach that file in the app. The helper sees public windows/groups, not native Arc Spaces/Favorites or Zen Essentials.
3. Review **Transfer plan** and **Browser support**. Select an existing destination profile for backup, or explicitly confirm a new/separately backed-up profile.
4. Quit selected profile browsers with **⌘Q**. Create the package outside both browser data directories. Large copies/checksums can take several minutes.
5. Read the package’s `READ ME.md`. Chromium destinations load its `Importer` folder via `chrome://extensions` → Developer mode → Load unpacked. Firefox/Zen load `Importer/manifest.json` via `about:debugging#/runtime/this-firefox` → Load Temporary Add-on. Safari uses manual bookmark HTML import.
6. Review categories in the helper and import. Up to 50 tabs open per run; repeat to continue. Keep the page open. Save the journal, then remove the helper when finished.

Temporary Firefox add-ons disappear on restart; save the journal and complete rollback first. A brand-new Firefox profile may need to finish initializing bookmarks. If the helper reports folders not ready, open its bookmark manager and retry; incomplete import trees are preserved.

## Portable-file-only mode

Attach a Browser Bridge capture JSON or Netscape-format bookmarks HTML. Enable **Portable file only** to avoid reading/backing up the original source profile. Only the selected input file and its portable data are preserved; the destination profile is still backed up when selected.

This is useful for Safari’s privacy-protected files or a browser on another Mac. General Safari ZIP/JSON exports are not decoded by this app; attach an HTML bookmarks file if the export provides one, extracting it first when necessary. Safari discovery lists data roots, not named profiles; choose the intended folder manually. Its source adapter can read `Bookmarks.plist` and `History.db` when macOS permits access.

A capture fills missing local tabs/bookmarks/history. If the native profile already has readable tabs, native organization takes precedence; the original capture remains in the package rather than guessing matches by URL. Check the capture’s manually selected browser label, profile and freshness yourself.

## Browser support

| Browser | Source route | Destination route | Native feature boundary |
|---|---|---|---|
| Helium | Chromium profile + live capture | Chromium helper | Vendor build not end-to-end verified |
| Arc | Chromium profile + live capture | Chromium helper | Sidebar Spaces/Favorites/nested folders are not decoded; known Storable files backed up when found |
| Zen | Mozilla profile + Zen session metadata | Firefox-family helper | Essentials → pins; spaces/nested folders → bookmark trees |
| Dia | Chromium profile + live capture | Chromium helper | Native Favorites/spaces and persistence are not created/verified |
| Chrome | Chromium profile + live capture | Chromium helper | Public APIs tested in isolated Chromium, not every Chrome release |
| Firefox | Mozilla profile/session + live capture | Firefox helper, 128+ | Newer group APIs detected at runtime; temporary add-on limitations apply |
| Brave | Chromium profile + live capture | Chromium helper | Vendor build not end-to-end verified |
| Safari | Readable plist/history files or HTML | Manual bookmark HTML import | No unpacked helper; tabs/groups become bookmark fallback where available; history activation not implemented |
| Edge | Chromium profile + live capture | Chromium helper | Vendor build not end-to-end verified |
| Opera | Chromium profile + live capture | Chromium helper | Vendor build not end-to-end verified |
| Vivaldi | Chromium profile + live capture | Chromium helper | Native workspaces/tab stacks not decoded |

Browser discovery includes standard data directories and a manual-folder option. Custom install paths, profiles and future formats may require an adapter update. “Family adapter” and “actual browser tested” are separate claims.

## Data categories

- **Bookmarks:** nested source trees plus exported tabs/workspaces are added under a new Browser Bridge folder. Existing trees remain intact. `Bookmarks.html` is an alternative; avoid importing it and helper bookmarks unless you want another copy.
- **Tabs/pins:** Firefox/Zen session files or optional live capture. Browser APIs open HTTP(S) URLs in order. Unsupported schemes remain in the archive. Live page titles are controlled by the browser.
- **Groups/folders:** nested bookmark trees where exposed; live groups use full folder paths because browser groups do not universally nest. Pinned Chromium tabs cannot belong to groups. Later batches reuse groups during the same browser session.
- **Spaces/Essentials/Favorites:** portable approximations only where the source exposes metadata. Generic capture windows approximate spaces. No native destination spaces/Favorites are created.
- **History:** source timestamps are exported where readable; capture is opt-in and bounded to the 10,000 most recent URLs. Import adds URLs with import-time timestamps only when destination visits do not already exist. Rollback retains history for review.
- **Passwords/passkeys/cookies:** original files remain encrypted in backups; no credential decryption or session activation. Use browsers’ own password export/import where offered. Passkeys require their provider; Keychain data is not exported.
- **Extensions/settings/other state:** original profile files are retained. Incompatible settings and extension data are not activated in the destination.

## Safety and package contents

Profile package creation requires selected browsers to be closed before and after copying. It stages output privately, verifies each copy with SHA-256, refuses overwrites/self-imports/outputs inside profile directories, and publishes the completed folder only at the end. Failure cleans up staged work; originals are not modified.

Packages contain `Backups/`, `backup-manifest.json`, `snapshot.json`, `transfer-report.json`, `Bookmarks.html`, target-specific instructions and a helper where supported. An attached capture is preserved separately. Selected profiles are backed up; known external `Local State`, profile registries and Arc/Dia Storable files under recognized browser roots are included in `-Global` folders when found. Other profiles and unknown external settings are not included. Caches, live locks and symlinks are omitted and omissions are reported.

**Owner-only permissions are not encryption.** Packages contain sensitive credential/session files and sometimes form state. Store them on an encrypted disk. Never upload packages, captures, journals or real-profile fixtures to a public repository. Opening imported tabs visits their websites normally.

## Undo and recovery

Explicit helper rollback removes its own bookmark trees, including edits made inside them, and closes unchanged imported tabs only during the same browser session. Navigated/restarted tabs and failed removals stay journaled for review. History is retained because browser APIs cannot atomically remove only an imported visit while protecting concurrent browsing. Retry preserves incomplete bookmark trees until explicit rollback.

Safari manual imports have no helper rollback. Raw profile recovery is manual: quit the browser, preserve its current profile elsewhere, and restore reviewed backup files. That reverts later activity and can require the original Mac/Keychain. The app never automatically replaces opaque browser databases.

## Build, test and contribute

```sh
bash build.sh
bash test.sh
```

Use Apple Swift tools on macOS and Node.js for helper tests. The build uses no package downloads or paid APIs. `swift scripts/brand.swift Assets/Brand` regenerates the original logo PNGs and ICNS icon locally. The app is signed ad hoc, not notarized for public distribution; no paid Apple account is required for a local source build.

For a synthetic preview: `open -n 'outputs/Browser Bridge.app' --args --demo` (export is disabled). Read-only CLI inventory: `swift run --build-system native bridge-inspect chrome '/path/to/profile'`; it prints counts/warnings, not URLs or credentials.

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), [verification](docs/verification.md), [MIT license](LICENSE), and [brand assets](Assets/Brand). Public source: [RitvikChunamari/browser-bridge](https://github.com/RitvikChunamari/browser-bridge).

## Primary references

[Chromium data directories](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md), [Firefox profiles](https://support.mozilla.org/en-US/kb/profiles-where-firefox-stores-user-data), [Firefox groups APIs](https://blog.mozilla.org/addons/2025/04/30/webextensions-support-for-tab-groups/), [WebExtension backgrounds](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/background), [Helium source](https://github.com/imputnet/helium), [Apple Safari import](https://support.apple.com/guide/safari/ibrw9ffa6d10/mac), [Arc native import behavior](https://resources.arc.net/hc/en-us/articles/19335089616791-Import-Bookmarks-Logins-History-Extensions-from-Your-Previous-Browser), and [OSI MIT license](https://opensource.org/license/mit).
