# Glossary

- **Source / destination**: the browser/profile data is exported from / imported into.
- **Profile**: a browser's stored browsing context and data directory.
- **Essential**: a Zen tab available across workspaces.
- **Pinned tab**: a tab retained by its browser; saved/reset destinations may be browser-specific.
- **Folder**: a named, possibly nested collection of bookmarks or tabs.
- **Space / workspace**: a browser-native organizational context. A captured window is an explicit approximation, not a native space.
- **Capture**: a portable snapshot made through public browser APIs; native metadata may not be exposed.
- **Migration package**: local profile/input backups, a portable snapshot, compatibility report and target-specific helper/files.
- **Approximation**: a transfer retaining information with different destination behavior.
- **Archive-only**: data preserved in backup without activation in the destination.
- **Portable-file-only mode**: migration from a selected capture or bookmark file without reading or backing up the original source profile.

## Connected migration

**Connected browser profile**:
A specific browser profile that has completed its one-time Browser Bridge setup and can participate in a coordinated transfer.

**Transfer**:
A user-started migration between a chosen source and destination, including backup, progress and a result report after one-time setup. Browser or macOS permission prompts may still require user action.
_Avoid_: Zero-setup transfer, universal feature parity
