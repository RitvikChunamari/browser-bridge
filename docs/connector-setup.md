# Connect a Mac browser profile

The connector and native host are free local software. No account, server or paid store enrollment is required. Safari remains a guided file transfer. Automatic transfer availability is a separate, evidence-based gate; a connected profile alone does not enable an unverified browser pair.

1. Open the packaged Browser Bridge app. Choose the source browser and exact profile folder.
2. Check the profile path in the browser’s version/support page (`chrome://version`, or Firefox/Zen `about:support`). In Connections, confirm that the selected folder is this profile. Browser extension APIs cannot independently reveal the filesystem profile path; this association is your explicit confirmation.
3. Choose **Install local host and create pairing code**. The app copies the native executable and connector into `~/Library/Application Support/Browser Bridge/`, and writes a user-local native messaging manifest for the selected browser. There is no administrator install or shell script to paste.
4. Chromium browsers: open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select the revealed connector folder. Firefox/Zen: open `about:debugging`, choose **This Firefox → Load Temporary Add-on**, and select the revealed `manifest.json`.
5. Open the connector’s toolbar button in that exact profile, enter an optional label, paste the ten-minute, single-use pairing code and choose **Connect profile**. Refresh Connections in the Mac app.
6. If wanted, use **Allow history** or **Allow tab groups** in the connector. This is optional and triggers browser permission prompts. Transfer must disclose categories that remain unavailable.

Firefox/Zen temporary add-ons disappear on browser exit. This installation is suitable for guided/local development, not a durable automatic route that quits and reopens the browser. A signed permanent add-on distribution is a future integration requirement; Browser Bridge must not call a temporary installation durable or enable such a route merely from protocol tests. Chromium unpacked extensions persist, but individual vendor acceptance still needs real validation.

Connection states show an authenticated heartbeat within 45 seconds, or **Waiting for browser**. They are not proof that a browser pair, vendor-specific spaces, credentials or every data category is supported. Profile identity is an extension-local UUID, paired with an app-issued secret and the explicitly confirmed filesystem profile. Disconnect revokes the secret; extension reinstall/reset requires pairing again. If a browser’s sync feature copies extension storage into another profile, disconnect and pair separately before use; Browser Bridge uses `storage.local`, not `storage.sync`.

## Privacy, recovery and limits

The native host uses stdio native messaging, not a localhost web server. Its manifests allow only the stable Browser Bridge extension IDs. It resolves the direct parent through macOS running-application identity, validates the OS-reported bundle identifier and executable against that bundle, and checks the browser-supplied extension origin; a manually selected extension label cannot claim a browser family. This is local application isolation, not protection from malicious programs already running as your macOS user.

The connector store is `~/Library/Application Support/Browser Bridge/Connector`, with a private directory and mode-600 state/lock files. It contains profile paths, authentication secrets, commands, captures and results. Never upload it in an issue. Operation results remain local while recovery may need them. Once a receipt completes or rollback finishes, its completed transport jobs are pruned; the receipt, capture, package and helper journal remain. Deleting the store revokes connections and loses pending results. Closing the app does not discard queued operations. Explicit disconnect revokes a connection; completed receipts should be retained before deleting local state.

One pending operation per profile prevents overlapping commands. The app alone queues jobs. Browser messages cannot select paths or queue work. A result is cached in extension-local storage before acknowledgement to avoid repeated effects after a dropped acknowledgement, and removed after acknowledgement succeeds. Import helpers retain their existing package journals for recovery. Importing tabs may require repeated batches of 50; a receipt must not call a partially imported package complete.

Commands are limited to 700,000 encoded bytes; host-to-browser frames remain below Chrome’s 1 MB limit. Completed captures/results are limited to 8 MiB and input frames to 12 MiB. Large transfers fail explicitly and use a file package rather than truncating silently. The durable state store has a 128 MiB read bound; users should archive completed transfers before deleting store data. Optional history capture remains bounded to 10,000 recent URLs.

## Local validation interface

Build `swift build --build-system native --product bridge-connect` and `--product browser-bridge-host`. `bridge-connect` is a local administrator/test interface, never available through extension messages:

```
bridge-connect STATE_ROOT pair BROWSER_ID PROFILE_PATH
bridge-connect STATE_ROOT list
bridge-connect STATE_ROOT enqueue CONNECTION_ID capture|import|verify|rollback INPUT_JSON
bridge-connect STATE_ROOT result JOB_ID
bridge-connect STATE_ROOT install BROWSER_ID HOST_EXECUTABLE CONNECTOR_RESOURCES HOME
```

`list` includes authentication secrets: keep its output private. The host accepts trusted process environment variable `BROWSER_BRIDGE_STATE_ROOT` for disposable-profile validation; no native message can override it. Native protocol: `pair` with code/profileID/label; `poll` with connectionID/secret/profileID/capabilities; `complete` with that authentication plus jobID/result. Responses include `ok`, an actionable `error` on failure, and host-inferred browser identity. Never put actual user captures, secrets or profile files into source control.

## Coordinated Transfer (verified routes only)

Transfer is enabled only for an exact browser/version route recorded in the shipping acceptance registry. It requires both selected profile connections and displays the normal-quit notice before starting. Every window in each selected app may close; unsaved-work prompts pause the flow and are never force-dismissed. The destination is reopened using the executable and version observed by the native host, with its exact profile arguments. A fresh authenticated heartbeat from that profile is required before import. Other profiles or unrelated browser executables cannot satisfy it.

The pipeline stores its phase and operation ID before issuing each command; captures current live state; requests normal quit; checks exact observed executable exit and Chromium singleton locks; creates the existing checksummed source and destination package; reopens the destination; imports all batches; and separately reads destination bookmarks, tabs, pin/group states and selected history URLs against intended data. A completed helper journal alone is insufficient. A mismatch or interruption retains the backup and a paused receipt, never a success claim. History timestamps remain import-time approximations, and non-HTTP(S) tabs/links stay archived.

Receipts and source captures are private local files below `~/Library/Application Support/Browser Bridge/Transfers`. Receipts redact connector secrets. The coordinated payload `connected-payload.json` uses the live capture and is retained in the package; native session exports are also retained, but may reflect older session state. Review the receipt’s warnings and verification observations. The destination remains open after completion; the source stays closed.

For explicitly disposable lifecycle validation only:

```
bridge-connect STATE_ROOT transfer-validate SOURCE_CONNECTION DEST_CONNECTION PACKAGE IMPORTER_RESOURCES DISPOSABLE_ROOT [OPTIONS_JSON_FILE]
```

Both profile paths must be inside the explicit disposable root. This local development command does not enable a production route or create acceptance evidence by itself. Optional JSON contains `bookmarks`, `tabs`, `history`, `groups` booleans; optional permissions must be granted in both profiles before selecting those categories. The shipping UI has no setting that bypasses route verification.

## Resume and rollback

Transfer receipts offer **Resume** after a pause or app interruption. Recovery checks the original profile identity, executable and version; reuses an existing checksummed package; rechecks every backup checksum and live-capture copy before further import; and consumes an already completed operation rather than issuing it twice. A cross-process lock prevents two app/CLI coordinators from running at once. A failed helper operation is retried only after explicit Resume, using its durable package journal.

The connected helper checkpoints source bookmark node identities and tab creation intentions. A retry adopts an unambiguous creation from the same browser session. It preserves edited partial trees and independently verifies the outcome. If tab identity becomes ambiguous or the browser restarts during a creation, it pauses for review instead of guessing and duplicating tabs. A verification failure is re-read on Resume, so a stale result cannot hide a user correction. This does not promise exactly-once effects across every browser crash: ambiguous cases require review.

**Cancel undelivered operation** cancels only work that the host has not handed to a browser, releasing its queue slot. It does not undo earlier completed effects. Cancelling a later import batch, verification or rollback step keeps the transfer paused and recoverable; Resume retries the step and Roll back remains available. Only a source capture cancelled before any import becomes a cancelled transfer. Claimed operations cannot safely be treated as undelivered; resolve the connector or wait for its result. A completed error is retained for diagnosis and does not permanently occupy the profile’s queue.

**Roll back…** requires explicit confirmation: helper-owned bookmark trees, including any edits inside those trees, are removed. Only unchanged tabs from the same browser session close. History, changed tabs, uncertain tab creations and earlier-session tabs remain, and the receipt says `rollbackPartial` when anything is retained. The source browser can be removed after migration; rollback requires only the original destination connection. A removed/re-paired destination is a different identity and cannot silently receive old recovery commands. Original profile backups are retained. Raw profile restoration remains a manual, browser-closed operation; Browser Bridge does not overwrite opaque live databases.

Local validation commands:

```
bridge-connect STATE_ROOT receipts
bridge-connect STATE_ROOT receipt RECEIPT
bridge-connect STATE_ROOT resume-validate RECEIPT DISPOSABLE_ROOT
bridge-connect STATE_ROOT rollback-validate RECEIPT DISPOSABLE_ROOT
```

The rollback validation command is explicit acknowledgement of the same helper-tree deletion/history-retention behavior. The shipping app asks in its own confirmation dialog. Production automatic readiness remains an immutable, exact browser/version/executable acceptance list; unverified pairs retain the guided package route.

## Preserve the destination’s existing setup

New transfers capture a separate destination baseline before requesting quit. Chromium reopening explicitly requests `--restore-last-session` for that exact profile, without changing its startup preferences. Before applying anything, Browser Bridge independently captures the reopened destination and checks that its previous HTTP(S) tabs, pin states, exposed tab-group names, duplicate counts and nested bookmark links remain. It checks that baseline again after import, allowing added items. A missing baseline item pauses recovery instead of calling the transfer additive or complete. Existing browser-internal tabs, page contents, active sessions and native workspace layouts are outside this baseline check and remain subject to the stated archive/guided limits.

The baseline and its checksum are stored privately beside the receipt; its observed preservation report is recorded separately from imported-item verification. Older receipts remain readable and resumable, with an explicit warning that destination baseline preservation was not independently checked. A browser update, startup prompt, disabled connector or failed session restore blocks automatic apply and may require the user to reopen the previous session from browser History before Resume.

For development and disposable native UI validation only, launch the Mac app, CLI and native host with the same trusted process environment variable `BROWSER_BRIDGE_STATE_ROOT`. It selects their private connector store; receipts remain in its parent’s `Transfers` directory. The normal default is unchanged. This is not a product setting or an extension-message field, and does not enable unverified automatic routes.
