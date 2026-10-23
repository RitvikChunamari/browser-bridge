# Browser Bridge expansion
Status: ready-for-agent

## Problem Statement
The existing manager only exports Zen for Dia. Users need a free, open-source macOS manager that can move a portable browsing setup between Helium, Arc, Zen, Dia, Chrome, Firefox, Brave, Safari, Edge, Opera and Vivaldi, with honest limits for native browser features.

## Solution
Rename to Browser Bridge, provide an original minimal vector logo and Mac icon, adopt MIT, and expose source/destination browser/profile selection. Use local profile adapters and optional capture helpers, immutable backups, a neutral snapshot, and destination-specific import helpers or file instructions. Preserve unsupported data and display capabilities rather than claiming universal fidelity.

## User Stories
1. As a user, I want to choose any listed source browser and profile.
2. As a user, I want to choose a destination browser and back up its existing profile.
3. As a user, I want portable bookmarks, folder trees, history URLs, tabs, pins and groups where the browser supports them.
4. As a user, I want native spaces, Essentials and Arc Favorites either preserved by a verified adapter or explicitly archived/approximated.
5. As a user, I want to capture live browser tabs when an offline session is not readable.
6. As a user, I want Firefox-family and Chromium-family helpers, and Safari file-based fallback.
7. As a user, I want clear manual steps for credentials and unsupported data.
8. As a user, I want repeat imports, journal-based conservative rollback and no overwrite of originals.
9. As a contributor, I want MIT-licensed source, build instructions, security/privacy guidance and synthetic fixtures.
10. As a maintainer, I want browser adapters and a truthful tested/experimental/manual capability matrix.

## Implementation Decisions
Keep SwiftUI/system libraries. Add a catalog and family adapters behind a neutral snapshot interface. Source readers inspect backups when building packages. Helpers use public WebExtension APIs, with separate manifests for Firefox and Chromium. Safari uses supported file flows and explicitly lacks a universal live import API. A portable live capture can supplement absent local session data; raw captures remain included. No writes to opaque browser databases. All tooling remains free/local. Original branding is vector artwork, not vendor browser logos.

## Testing Decisions
User approved the existing export and safe import/rollback public boundaries extended across adapters. Synthetic profiles cover discovery, source decoding and immutable backup packages. Browser checks use isolated profiles. Family similarity is not recorded as actual-browser verification. Test what a user receives, not implementation shapes.

## Out of Scope
Windows/Linux app builds; automatic activation of encrypted cookies, passkeys or incompatible extension settings; unsupported native-space creation; paid services. Public hosting is prepared locally; repository publication requires a destination and review of release contents.
