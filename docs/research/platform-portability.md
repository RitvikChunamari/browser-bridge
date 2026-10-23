# Windows/Linux portability exploration

Facts-only exploration for the next platform scope. No product source, runtime installation, browser registration or VM configuration was changed. Updated scope supplied during exploration: Windows 10/11 x64, Windows 11 ARM64, Ubuntu 24.04 x64/ARM64, Debian/Fedora x64, while preserving the existing Mac app. Exact Debian/Fedora release baselines still need to be selected. Recommendations below are architectural judgments, not approved implementation decisions.

## What is reusable now

The strongest existing contract is the local capture/package/native-message format, not the SwiftUI screen. `Resources/Connector/{capture,import,verify}.mjs` already uses WebExtension APIs rather than AppKit. Stable extension IDs, schema-1 captures, package identity, permission disclosure, incremental bookmark/tab journals, observed verification and conservative undo can be reused across OSes, subject to actual vendor/API checks. `Tests/Importer` exercises those helpers on the existing Node runtime.

`Models.swift`, the HTML and Mozilla-session parsers, browser-family SQLite queries, portable capture validation and most transfer-state decisions are transferable logic. They are not currently a separately buildable portable module: the same BridgeCore target also imports macOS-specific facilities.

The current app is macOS-only: `Package.swift` targets macOS 14; `Sources/BrowserBridge/App.swift` imports SwiftUI, AppKit and UniformTypeIdentifiers. A universal Mach-O build adds Intel Mac support, not Windows PE or Linux ELF support.

## Concrete seams that need platform adapters

| Current code | Windows change | Linux change |
|---|---|---|
| `BrowserCatalog.dataPaths` is entirely `Library/...` paths; `BrowserReader` discovers a selected root | Resolve OS-known Local/Roaming AppData locations, installed vendor/channel and explicit custom user-data roots; retain explicit profile association | Resolve XDG config/state roots, native browser packages, and separately identified sandboxed packages/custom roots |
| `ConnectorInstallation` installs macOS files under Application Support | Per-user native-host executable/manifests and browser-specific registry registration; include uninstall/repair without administrator requirements where supported | Per-user absolute host executable and browser-specific manifest locations; handle packaging confinement separately |
| `BridgeHost` uses NSRunningApplication + bundle ID/executable/version | Read real process identity/executable/version through Windows APIs; investigate actual browser launch ancestry rather than assuming a raw parent-path pattern | Resolve process identity/executable and package context; validate real browser launcher/broker behavior and confinement |
| `MacBrowserLifecycle` uses NSWorkspace, normal terminate and `/bin/ps` | Normal close of the exact browser windows/process context, respect user prompts, wait for background processes/locks, reopen exact executable/profile | Desktop/browser-specific graceful close with prompt handling; Wayland/X11 differences require real desktop checks, not a blanket kill signal |
| `ConnectorStore` and coordinator use Darwin `open`, `flock`, `O_NOFOLLOW`, POSIX mode bits | Windows locks and user-only ACLs; safe replacement, reparse-point checks and case-insensitive path containment | Linux locking/no-follow checks, user-only modes, safe atomic replacement and canonical paths |
| `PackageBuilder`/coordinator use CryptoKit SHA-256 and POSIX permissions | Portable streaming SHA-256 + Windows file protections; preserve checksum-before-apply behavior | Portable SHA-256 and POSIX protection adapter |
| `CSQLite` links the system `sqlite3` module | Bundle/build an appropriately licensed SQLite dependency and a compatible module/link setup; do not assume a Windows system SQLite | Declare/install/build a pinned SQLite dependency for the chosen package/runtime |
| SwiftUI panels, alerts, Finder and UserDefaults | New Windows UI shell; OS-native folder selection and durable settings | New Linux UI shell; desktop folder selection and durable settings |
| `AutomaticRoutes` is compile-time arm64 plus two exact browser versions | Add explicit OS, architecture, browser build/channel and evidence dimensions | Same, additionally distinguish package/confinement context and tested desktop where relevant |
| macOS `.app` + lipo + codesign build | Separate Windows build, executable/installer packaging and install/uninstall validation | Separate Linux build and package/runtime dependency validation |

Chrome documents Windows native-host registration through per-user/machine registry keys and binary stdio mode, while Linux uses browser-specific manifest paths. Its host-to-browser size bound and four-byte framing remain applicable. Reuse the bounded protocol; do not reuse Mac registration paths or text-mode Windows I/O. [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)

Firefox uses `allowed_extensions` and its own native-manifest registration, including `HKCU\SOFTWARE\Mozilla\NativeMessagingHosts` on Windows. The Chromium origin manifest cannot substitute for Firefox setup. [Mozilla native manifests](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_manifests)

Windows has a native exclusive-lock API; POSIX `flock` is not the Windows implementation. A normal window-close request can allow an unsaved-work prompt. Neither fact proves that every browser window/background process will close safely. [LockFileEx](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-lockfileex), [WM_CLOSE](https://learn.microsoft.com/en-us/windows/win32/learnwin32/closing-the-window)

### Small interfaces worth preserving

- **Browser platform catalog:** discover installed browser packages, source/target profiles and supported installation contexts; do not equate a family with a verified vendor.
- **Private local state:** bounded read/write, user-only access, atomic commit and cross-process lease. Keep transport jobs separate from redacted durable receipts.
- **Connector installation/identity:** install/repair/remove a scoped host; identify an actual caller independently from a user-selected label; pair an extension-local UUID to an explicitly confirmed filesystem profile.
- **Transfer lifecycle:** normal close, prove selected profiles are quiescent, reopen exact executable/profile. The existing `TransferLifecycle` seam is useful, but `MacBrowserLifecycle.backupBlockers` is still the coordinator's hard-coded default and must move behind platform composition.
- **Package engine:** immutable capture input, streaming verified backup, portable payload, manifest and receipt. Path/ACL/lock behavior is part of this interface, not incidental plumbing.
- **Transfer coordinator:** capture source and destination baseline → graceful close → backup → exact reopen → fresh profile handshake → apply batches → imported-state verification → baseline recheck → receipt/recovery. Reuse this order and failure semantics.

Do not attempt to create a platform-neutral `quitBrowser()` that silently maps to forceful process termination. Linux has no demonstrated universal desktop quit path in this investigation. If a close cannot respect prompts or a background process/lock remains, the supported outcome is an actionable pause.

## Portable-core options while keeping SwiftUI on Mac

| Option | Reuse and benefit | Real work / limits |
|---|---|---|
| Extract a portable Swift core/CLI first; add platform adapters and Windows/Linux UI shells | Maximum reuse of current parsers, models and coordinator; existing Mac UI can remain a client | Remove Darwin/AppKit coupling, supply Windows/Linux storage/lifecycle/registration, replace direct CryptoKit usage or conditionally use Swift Crypto, bundle SQLite/runtime dependencies, add new GUI shells |
| Rust engine/native host, optional Tauri Windows/Linux UI; keep Mac SwiftUI as a client | A compact native executable and explicit OS adapters; one durable engine could eventually serve all shells | Rust is not installed here; rewrite/migrate the core semantics behind cross-language contracts, not merely translate files. Tauri needs platform webview/build dependencies and real UI testing |
| Node/TypeScript engine + Electron Windows/Linux shell; retain existing Mac shell initially | Existing JS helpers/tests and local Node tooling reduce initial setup; Electron supplies a common rendering/runtime stack | Package a native-host entry point with binary framing, implement native OS identity/lifecycle/file protection, choose and validate SQLite packaging, carry a larger bundled runtime. Do not expose unrestricted Node access to rendered content |

Swift has official Windows and Ubuntu 24.04 toolchain distributions; retaining Swift for a console core is viable in principle. That does not make SwiftUI or the current package portable. [Swift Windows](https://www.swift.org/install/windows/), [Swift Ubuntu 24.04](https://www.swift.org/install/linux/ubuntu/24_04/)

Apple's open-source Swift Crypto provides much of the CryptoKit interface across supported Swift platforms, making it a plausible hash implementation adapter after dependency/build validation. It is not installed or added by this exploration. [Swift Crypto](https://github.com/apple/swift-crypto)

Rust supports native Windows x64 MSVC tooling; its documented non-Windows-to-MSVC cross-compilation path is unsupported. Tauri uses WebView2 on Windows and WebKitGTK dependencies on Ubuntu. Those are real prerequisites, not a free cross-build switch on this Mac. [Rust Windows target](https://doc.rust-lang.org/rustc/platform-support/windows-msvc.html), [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/)

Electron embeds Chromium/Node and supports Windows/Linux desktop apps. A standalone Node executable is also an option for a CLI/host, but SEA packaging has version/platform and native-addon constraints and must be evaluated against a pinned Node version rather than assumed from this machine's runtime. [Electron](https://www.electronjs.org/docs/latest), [Node SEA](https://nodejs.org/api/single-executable-applications.html)

**Recommendation for the next decision:** preserve the Mac app and first lock down language-neutral schema/golden fixtures plus the platform interfaces above. If minimum rewrite is the priority, prototype extracting the Swift console core before selecting a new engine language. If a shared Windows/Linux UI and a Rust engine are deliberate long-term choices, budget a migration with parity tests and keep the working Mac engine until the new engine passes them. Installed Node alone is not a reason to replace a tested backup/recovery engine. No option eliminates native Windows/Linux adapter work.

## Local free tooling inventory

Observed through PATH and common installation locations only; another nonstandard installation may exist.

- Apple Silicon/macOS host; Swift 6.4 Command Line Tools and xcrun available.
- Node `v24.14.0`, npm `11.9.0`, Python `3.14.0` available.
- Rust (`rustc`, `cargo`) and .NET (`dotnet`) not found in PATH/common checked locations.
- Docker, Podman, Lima, QEMU x86/ARM, Multipass, OrbStack CLI, Colima, UTM CLI, Parallels CLI, VirtualBox CLI and libvirt CLI not found in PATH. Their common app locations were also absent where checked.
- No Docker socket found at `/var/run/docker.sock` or the common user Docker socket location. No guest OS was started or inspected. No Windows 11 or Ubuntu 24.04 runtime evidence exists from this inventory.
- No packages, SDKs, hypervisors, trial software, guest images or paid services were installed/enabled. No browser was opened or modified.

## Test and release evidence needed

1. Keep shared capture/package/receipt fixtures and helper tests. Add cross-language contract comparisons if an engine changes language, including duplicate links/tabs, folder graphs, timestamp units, unsupported schemes, interrupted creation and partial rollback.
2. Run private-state/frame fuzz/limit tests and platform filesystem tests: ACLs/modes, junction/symlink escapes, locked databases, long/non-ASCII paths, atomic replacement, concurrency and disk-full behavior.
3. Validate actual per-user install/repair/uninstall and native host invocation on each OS, browser, architecture and package channel. Confirm that caller identity is observed, not extension-selected.
4. Exercise real signed/stable browser builds in disposable profiles: capture → prompt-respecting close → lock-free checksum backup → exact profile reopen → authenticated connector → full import → independent intent and baseline checks. Repeat interruption/restart/retry and undo.
5. Verify each requested Windows version/architecture specifically. A Windows Server x64 CI result is not Windows 10/11 x64 desktop evidence. Verify Ubuntu 24.04 on x64 and ARM64 and selected Debian/Fedora x64 releases under the intended desktop/browser package; a headless native-package check is not proof of Snap/Flatpak/Wayland behavior.
6. Key acceptance by OS/architecture/browser version/channel/direction and data category. Keep automatic routes disabled where that evidence is absent. Do not remove version gates solely to make more selectors look supported.
7. Validate installer artifacts on clean target systems and state exactly which runtime components are bundled/required. Avoid requiring users to install a development language runtime unless that is an explicit product decision.

Standard GitHub-hosted runners in this public repository can provide free build and logic-test infrastructure; use explicit `ubuntu-24.04` and documented standard Windows labels, with no paid larger runners or new billed service. GitHub's x64 Windows standard images are Windows Server variants, not Windows 10/11 x64 evidence. Standard public runner labels also include `windows-11-arm` and `ubuntu-24.04-arm`; these can supply real target-architecture build/API checks without a paid runner, although interactive browser/session acceptance still needs an appropriate desktop test. CI support complements, rather than replaces, target desktop validation. [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions), [runner images](https://github.com/actions/runner-images), [hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

## Interview decisions still required

- Minimum release behavior per OS: buildable preview/guided export, or verified automatic transfer before release?
- Engine strategy: portable Swift extraction first, or an intentional language migration?
- Initial browser pairs and Linux package channels, rather than an unqualified all-pairs claim?
- Access to existing licensed Windows 10/11 x64 and the requested Linux desktop test environments or trusted testers?
- Whether all-browser one-click means best available portable categories with visible limits, since native spaces, credentials and active sessions do not become interoperable through an OS port?


## Expanded target / credential follow-up

Rust's documented tier-1 host-tool targets include Windows MSVC x64/ARM64 and Linux GNU x64/ARM64. This establishes a practical native-engine build matrix, not browser acceptance. Windows MSVC requires native Windows build tooling; the official Rust documentation does not support building MSVC targets from this Mac. Debian/Fedora packaging still needs explicit supported releases and dependency baselines. [Rust platform support](https://doc.rust-lang.org/rustc/platform-support.html)

Given the expanded targets, a **Rust portable engine and native host, Tauri Windows/Linux shell, existing SwiftUI Mac shell** is a pragmatic long-term choice if the user approves an engine migration. It gives all shells one state/backup/receipt implementation, while OS adapters remain explicit. Preserve the current Mac engine until contract and complete-seam parity passes, then let SwiftUI call the portable engine through a narrow local process interface. Do not silently maintain two independently evolving coordinators. This is a recommendation, not work begun: Rust/Tauri are not installed here.

Credentials and authenticated sessions are separate from restoring open tabs. Existing helpers explicitly omit passwords/cookies; their manifests have no cookie permission and their snapshot schema has only password/cookie counts. Supporting these categories requires a new consented sensitive-data format and permissions, OS/browser authentication adapters, protected transient transport, destination-supported import and observed result reporting. It is not a boolean added to the current snapshot.

The WebExtension cookies interface can read/write accessible cookie data with appropriate permissions and supports partitioned-cookie distinctions. That is a potential browser-authorized path, not proof that a destination site will accept the resulting login. Passwords, passkeys, cookie records, partition keys, OS-bound encryption and remote device/MFA checks must be capability-tested separately. User consent does not make an unavailable API or a device-bound authentication credential portable. Keep success, partial import, reauthentication-required and unsupported outcomes distinct, with no sensitive values in logs/receipts. [Mozilla cookies API](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/cookies)

No credential/session decryption, cookie capture, authentication prompt or browser modification was attempted in this exploration. A requested guarantee that every site stays signed in across all browsers and OSes cannot be inferred from the available APIs or the existing Mac route evidence.

## Selected package baselines

The initial x64 package installation checks target Debian 13 and Fedora 44, alongside native Ubuntu 24.04 builds. These are dependency/container checks, not desktop/browser acceptance. Debian 13 provides WebKitGTK 4.1; Fedora 44 was released April 2026. [Debian package](https://packages.debian.org/trixie/libwebkit2gtk-4.1-0), [Fedora download](https://www.fedoraproject.org/workstation/download/).
