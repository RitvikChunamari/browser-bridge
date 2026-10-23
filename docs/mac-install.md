# Free Mac developer preview installation

Browser Bridge's current Mac downloads are **ad-hoc signed, unnotarized developer previews**. They have not completed Apple's notarization check. No paid membership is required to use the preview, but macOS may block a downloaded copy. This is not a claim that the app has been independently security audited.

1. Download the archive and its matching SHA-256 file from the [official releases](https://github.com/RitvikChunamari/browser-bridge/releases). Avoid third-party reuploads.
2. In Terminal, change to the download folder and run `shasum -a 256` followed by the archive filename. Compare the complete result with the matching published checksum. A match confirms the file matches that release, not that its contents are safe.
3. Extract the archive and move Browser Bridge to Applications.
4. Try opening it. If macOS says Apple could not verify the developer, click **Done**, then open **System Settings → Privacy & Security**, find Browser Bridge and choose **Open Anyway**. Authenticate and confirm only if you trust this build. Availability can depend on Mac management policies.

Keep Gatekeeper enabled. No Terminal command to disable protection or strip quarantine is required. An app-specific exception does not notarize the app. For an alert saying malware was detected or that the app will damage your computer, stop rather than treating it as this unidentified-developer warning.

For a local source build, see the [README](../README.md). Future notarized distribution requires the separate [trusted release procedure](macos-release-security.md).

[Apple's explanation and opening instructions](https://support.apple.com/en-us/102445).
