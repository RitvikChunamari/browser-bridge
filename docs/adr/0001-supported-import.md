# Use browser APIs for the destination

Dia's local tabs.db is not readable as ordinary SQLite. Direct writes risk corruption and would rely on undocumented formats. Use an explicitly loaded local extension with Chromium bookmark/history/tab/group APIs. Preserve all original profile data separately. This limits fidelity for Dia-specific structures, passwords and cookies; the preview and report must expose that limitation.
