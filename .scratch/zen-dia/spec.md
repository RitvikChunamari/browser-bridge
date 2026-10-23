# Zen → Dia migration
Status: ready-for-agent

Build a free, local macOS app. User approved merging rather than overwriting, backups of both browsers, preserving Zen, local tracking/default labels, and closest representable structures plus an original backup for unsupported data.

Scope: tabs, Essentials, pins, names/order, folders/nesting, spaces, bookmarks, history, passwords, cookies, extensions, settings and remaining profile data. Every category must have an honest destination status. Exact native fidelity is contingent on supported Dia APIs, never inferred from a successful export.

Workflow: discover profiles, inspect preview, create private backup/export package while browsers are closed, use a bundled unpacked extension in the chosen Dia profile to import supported categories, provide a downloadable import journal/rollback. Unsupported categories stay in raw archives with explicit instructions. No direct writes to opaque Dia databases.

User approved test boundaries: (1) Zen export fidelity and (2) preview/apply/restore safety with synthetic profiles. Real Dia acceptance must be distinguished from synthetic checks.

Open implementation boundary: no supported native API yet confirmed for Dia Favorites, spaces or nested live groups. Preserve workspace structure in bookmark folders and use individually selected workspace imports; never silently convert a workspace into a separate authenticated profile.
