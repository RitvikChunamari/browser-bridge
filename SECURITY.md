# Security and privacy

The app processes highly sensitive local browser data. It does not upload profiles or use telemetry. Opening imported tabs visits their websites normally.

Migration packages include encrypted credential files and session/form data. Owner-only permissions do not encrypt the files; use an encrypted disk. Keychain data is not exported. No profile, live capture or journal belongs in a public issue or source release.

Source/destination profiles remain untouched during package creation. Backups are copied and checked while browsers are closed. Helpers use public browser APIs; they do not inject into opaque databases. Rollback is conservative, and history URLs remain for manual review.

Until a private reporting channel is configured for the public repository, do not disclose sensitive details in public. Contact the repository owner privately first, or open a minimal issue requesting a private channel without exploit details, URLs, captures or profile contents. No email address or supported-version promise is invented by this project.

Before publishing a release, inspect its file list and exclude `work/`, local migration packages, captures, journals, credentials and personal screenshots. Only source and deliberately generated release assets belong in distribution archives.
