# Product
<!-- impeccable:product-schema 1 -->

## Platform
macOS native desktop (SwiftUI).

## Stack
Native SwiftUI and system SQLite/CryptoKit. Local Chromium/Firefox WebExtensions, Safari file-based fallback. No paid services or runtime dependencies in the built app.

## Users
People moving browsing setups between local browsers, plus open-source contributors adding adapters and fixtures.

## Product Purpose
Browser Bridge is a reusable migration manager for Helium, Arc, Zen, Dia, Chrome, Firefox, Brave, Safari, Edge, Opera and Vivaldi. It previews what transfers, makes verified local backups and produces target-specific packages while preserving originals.

## Capabilities and Constraints
User confirmed Browser Bridge naming, minimal connected-window mark, MIT license and all eleven browsers. Include portable bookmarks, tabs, pins, folders/groups, spaces where exposed, history and raw profile data. Mark native-feature approximations, manual credentials, archive-only categories and vendor-specific verification explicitly. Live captures can supplement missing session data. Portable-file-only mode preserves only its selected input, not the original source profile. Use free/local tooling. Keep public release archives free of user data.

## Product Principles
- Preserve originals before importing.
- Expose category-specific capability and verification boundaries.
- Keep browser data local.
- Support repeat imports and conservative rollback.
- Make adapters and synthetic tests accessible to contributors.

## Connected release direction
Finish macOS first. After one-time setup per browser, users choose a source and destination and click Transfer; backup, progress and a result report are coordinated automatically, with browser/macOS prompts where required. The product website will use a dark, expressive direction with the existing Browser Bridge identity, hosted on GitHub Pages. Windows, iOS, Android and Linux are requested as Coming soon, without a release date or feature-parity promise. All eleven browsers remain visible; automatic Transfer is enabled only for pairs that pass real end-to-end checks, with guided fallbacks for the rest. Transfer may request a normal quit after capture, wait for exit, back up, and reopen the destination; it pauses on unsaved-work prompts and never force-quits. Distribution stays free with explicit local connector setup; no paid enrollment is authorized.
