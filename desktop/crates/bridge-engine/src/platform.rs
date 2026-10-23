use super::*;
use std::process::Command;
const BROWSERS: &[&str] = &[
    "chrome", "brave", "firefox", "zen", "edge", "opera", "vivaldi", "helium", "arc", "dia",
    "safari",
];
pub fn browser_available(browser: &str, platform: &str) -> bool {
    BROWSERS.contains(&browser)
        && match browser {
            "safari" => platform == "macos",
            "arc" | "dia" => matches!(platform, "macos" | "windows"),
            _ => true,
        }
}
fn connector_supported(browser: &str) -> bool {
    matches!(std::env::consts::OS, "linux" | "windows")
        && matches!(
            browser,
            "chrome" | "brave" | "firefox" | "edge" | "opera" | "vivaldi"
        )
}
pub fn discover_profiles(browser: &str, root: &Path) -> Vec<Value> {
    let mut profiles = vec![];
    if root.join("Preferences").is_file() || root.join("prefs.js").is_file() {
        profiles.push(json!({"browser":browser,"name":root.file_name().unwrap_or_default().to_string_lossy(),"path":root}));
    }
    if let Ok(entries) = fs::read_dir(root) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir()
                && (path.join("Preferences").is_file() || path.join("prefs.js").is_file())
            {
                profiles.push(json!({"browser":browser,"name":entry.file_name().to_string_lossy(),"path":path}));
            }
        }
    }
    profiles
}
pub fn validate_browser(browser: &str) -> Result<()> {
    if !BROWSERS.contains(&browser) {
        return fail("Unknown browser");
    };
    if browser_available(browser, std::env::consts::OS) {
        Ok(())
    } else {
        fail("This browser is unavailable on this operating system")
    }
}
#[allow(unused_mut)]
fn installations() -> Vec<(String, PathBuf)> {
    let mut result = vec![];
    #[cfg(target_os = "linux")]
    for (name, path) in [
        ("chrome", "/opt/google/chrome/chrome"),
        ("brave", "/opt/brave.com/brave/brave"),
        ("firefox", "/usr/lib/firefox/firefox"),
        ("firefox", "/usr/lib64/firefox/firefox"),
        ("edge", "/opt/microsoft/msedge/msedge"),
        ("vivaldi", "/opt/vivaldi/vivaldi-bin"),
        ("opera", "/usr/lib/x86_64-linux-gnu/opera/opera"),
    ] {
        let path = PathBuf::from(path);
        if let Ok(path) = path.canonicalize() {
            result.push((name.into(), path))
        }
    }
    #[cfg(windows)]
    for base in [
        std::env::var_os("LOCALAPPDATA"),
        std::env::var_os("PROGRAMFILES"),
        std::env::var_os("PROGRAMFILES(X86)"),
    ]
    .into_iter()
    .flatten()
    {
        for (name, relative) in [
            ("chrome", "Google/Chrome/Application/chrome.exe"),
            ("brave", "BraveSoftware/Brave-Browser/Application/brave.exe"),
            ("edge", "Microsoft/Edge/Application/msedge.exe"),
            ("firefox", "Mozilla Firefox/firefox.exe"),
            ("vivaldi", "Vivaldi/Application/vivaldi.exe"),
            ("opera", "Programs/Opera/opera.exe"),
        ] {
            if let Ok(path) = PathBuf::from(&base).join(relative).canonicalize() {
                result.push((name.into(), path))
            }
        }
    }
    result
}
pub fn discover() -> Value {
    let installations = installations();
    let home = dirs::home_dir().unwrap_or_default();
    let config = dirs::config_dir().unwrap_or_else(|| home.join(".config"));
    let local = dirs::data_local_dir().unwrap_or_else(|| home.join(".local/share"));
    let roaming = dirs::data_dir().unwrap_or_else(|| home.join(".local/share"));
    let mut browsers = vec![];
    for browser in BROWSERS
        .iter()
        .filter(|browser| browser_available(browser, std::env::consts::OS))
    {
        let root = if cfg!(windows) {
            match *browser {
                "chrome" => local.join("Google/Chrome/User Data"),
                "brave" => local.join("BraveSoftware/Brave-Browser/User Data"),
                "edge" => local.join("Microsoft/Edge/User Data"),
                "firefox" => roaming.join("Mozilla/Firefox/Profiles"),
                "zen" => roaming.join("zen/Profiles"),
                "vivaldi" => local.join("Vivaldi/User Data"),
                "opera" => roaming.join("Opera Software/Opera Stable"),
                _ => config.join(browser),
            }
        } else {
            match *browser {
                "chrome" => config.join("google-chrome"),
                "brave" => config.join("BraveSoftware/Brave-Browser"),
                "edge" => config.join("microsoft-edge"),
                "firefox" => home.join(".mozilla/firefox"),
                "zen" => home.join(".zen"),
                _ => config.join(browser),
            }
        };
        let profiles = discover_profiles(browser, &root);
        browsers.push(json!({"browser":browser,"available":true,"connectorSupported":connector_supported(browser),"installed":installations.iter().any(|(b,_)|b==browser),"profiles":profiles,"readiness":"guided","note":if connector_supported(browser){"Explicit profile selection is available. Automatic platform acceptance is pending."}else{"Native connector identity/installation is not supported on this platform; use browser-managed export/import."}}));
    }
    json!(browsers)
}
/// Resolve the native caller from OS process metadata, then require an exact installed executable.
/// Unknown launchers, sandbox wrappers and unregistered custom builds fail closed.
pub fn observe_caller(origin: &str) -> Result<Caller> {
    let mut system = sysinfo::System::new_all();
    system.refresh_all();
    let own = sysinfo::Pid::from_u32(std::process::id());
    let parent = system
        .process(own)
        .and_then(|p| p.parent())
        .and_then(|pid| system.process(pid))
        .ok_or_else(|| EngineError("Cannot observe browser parent process".into()))?;
    let executable = parent
        .exe()
        .ok_or_else(|| EngineError("Browser executable unavailable".into()))?
        .canonicalize()?;
    let browser = installations()
        .into_iter()
        .find(|(_, path)| *path == executable)
        .map(|(name, _)| name)
        .ok_or_else(|| {
            EngineError("Native host was not launched by a supported installed browser".into())
        })?;
    let expected = if matches!(browser.as_str(), "firefox" | "zen") {
        FIREFOX_ORIGIN
    } else {
        CHROMIUM_ORIGIN
    };
    if origin != expected {
        return fail("Untrusted extension origin");
    };
    Ok(Caller {
        browser,
        executable,
        version: "unverified".into(),
        origin: origin.into(),
    })
}
/// Prepare per-browser files without changing OS registration. Root is trusted composition.
pub fn prepare_connector_installation(
    browser: &str,
    host: &Path,
    connector: &Path,
    root: &Path,
) -> Result<Value> {
    validate_browser(browser)?;
    check_regular(host)?;
    validate_tree(connector)?;
    private_directory(root)?;
    let root = root.canonicalize()?;
    let executable = host.canonicalize()?;
    let connector = connector.canonicalize()?;
    let destination = root.join("Connectors").join(browser);
    if destination.starts_with(&connector) || connector.starts_with(&destination) {
        return fail("Connector resources and installation must be separate directories");
    };
    private_directory(&destination)?;
    for entry in walkdir::WalkDir::new(&connector).follow_links(false) {
        let entry = entry.map_err(|e| EngineError(e.to_string()))?;
        if entry.file_type().is_symlink() {
            return fail("Connector resources contain a symlink");
        };
        let target = destination.join(
            entry
                .path()
                .strip_prefix(&connector)
                .map_err(|_| EngineError("Invalid connector resource path".into()))?,
        );
        if entry.file_type().is_dir() {
            private_directory(&target)?;
        } else {
            check_regular(entry.path())?;
            if fs::metadata(entry.path())?.len() > 1024 * 1024 {
                return fail("Connector resource exceeds the installation limit");
            };
            atomic_bytes(&target, &fs::read(entry.path())?)?;
        }
    }
    let firefox = matches!(browser, "firefox" | "zen");
    if firefox {
        let variant: Value =
            serde_json::from_slice(&fs::read(connector.join("manifest-firefox.json"))?)?;
        if variant["browser_specific_settings"]["gecko"]["id"] != FIREFOX_ORIGIN {
            return fail("Firefox connector identity differs from the allowed native origin");
        };
        atomic_json(&destination.join("manifest.json"), &variant)?;
    }
    let manifest = if firefox {
        json!({"name":HOST,"description":"Browser Bridge local connector","path":executable,"type":"stdio","allowed_extensions":[FIREFOX_ORIGIN]})
    } else {
        json!({"name":HOST,"description":"Browser Bridge local connector","path":executable,"type":"stdio","allowed_origins":[CHROMIUM_ORIGIN]})
    };
    let directory = root.join("NativeMessagingHosts").join(browser);
    private_directory(&directory)?;
    let path = directory.join(format!("{HOST}.json"));
    atomic_json(&path, &manifest)?;
    Ok(json!({"connectorPath":destination,"manifestPath":path}))
}
pub fn install_host(browser: &str, host: &Path, connector: &Path) -> Result<Value> {
    install_host_at(browser, host, connector, &default_root())
}
pub(crate) fn install_host_at(
    browser: &str,
    host: &Path,
    connector: &Path,
    root: &Path,
) -> Result<Value> {
    validate_browser(browser)?;
    if !connector_supported(browser) {
        return fail("Native connector installation is not supported for this browser/platform; use browser-managed export/import");
    };
    let prepared = prepare_connector_installation(browser, host, connector, root)?;
    #[cfg(target_os = "linux")]
    let directory = {
        let home =
            dirs::home_dir().ok_or_else(|| EngineError("Home directory unavailable".into()))?;
        let config = dirs::config_dir().unwrap_or_else(|| home.join(".config"));
        match browser {
            "firefox" | "zen" => home.join(".mozilla/native-messaging-hosts"),
            "chrome" => config.join("google-chrome/NativeMessagingHosts"),
            "brave" => config.join("BraveSoftware/Brave-Browser/NativeMessagingHosts"),
            "edge" => config.join("microsoft-edge/NativeMessagingHosts"),
            "vivaldi" => config.join("vivaldi/NativeMessagingHosts"),
            "opera" => config.join("opera/NativeMessagingHosts"),
            _ => return fail("This browser needs manual native-host registration on Linux"),
        }
    };
    #[cfg(windows)]
    let directory = root.join("NativeMessagingHosts").join(browser);
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = prepared;
        fail("The portable connector installer targets Windows and Linux; use the native Mac app on macOS")
    }
    #[cfg(any(windows, target_os = "linux"))]
    {
        private_directory(&directory)?;
        let path = directory.join(format!("{HOST}.json"));
        let manifest: Value =
            serde_json::from_slice(&fs::read(field(&prepared, "manifestPath")?)?)?;
        atomic_json(&path, &manifest)?;
        #[cfg(windows)]
        {
            let key = match browser {
                "chrome" => "Google\\Chrome",
                "brave" => "BraveSoftware\\Brave-Browser",
                "edge" => "Microsoft\\Edge",
                "firefox" | "zen" => "Mozilla",
                "vivaldi" => "Vivaldi",
                "opera" => "Opera Software",
                _ => return fail("Manual registration required for this Windows browser"),
            };
            let status = Command::new("reg.exe")
                .args([
                    "ADD",
                    &format!("HKCU\\Software\\{key}\\NativeMessagingHosts\\{HOST}"),
                    "/ve",
                    "/t",
                    "REG_SZ",
                    "/d",
                ])
                .arg(&path)
                .arg("/f")
                .status()?;
            if !status.success() {
                return fail("Per-user native messaging registration failed");
            }
        }
        Ok(
            json!({"installed":true,"manifestPath":path,"connectorPath":prepared["connectorPath"],"instructions":"Load the returned private browser-specific connector folder as an unpacked extension, then enter the pairing code. Firefox requires a signed extension for persistence across restart."}),
        )
    }
}
#[cfg(windows)]
pub(crate) fn private_acl(path: &Path) -> Result<()> {
    let script="$p=$env:BROWSER_BRIDGE_ACL_PATH;$sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User;$acl=New-Object System.Security.AccessControl.DirectorySecurity;$acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false);$rule=New-Object System.Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow');$acl.AddAccessRule($rule);Set-Acl -LiteralPath $p -AclObject $acl -ErrorAction Stop";
    let status = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .env("BROWSER_BRIDGE_ACL_PATH", path)
        .status()?;
    if status.success() {
        Ok(())
    } else {
        fail("Cannot establish owner-only Windows storage permissions")
    }
}
pub(crate) fn reopen(c: &Connection) -> Result<()> {
    check_regular(&c.executable)?;
    let mut process = Command::new(&c.executable);
    if matches!(c.browser.as_str(), "firefox" | "zen") {
        process.arg("-profile").arg(&c.path);
    } else {
        process
            .arg("--restore-last-session")
            .arg(format!(
                "--user-data-dir={}",
                c.path
                    .parent()
                    .ok_or_else(|| EngineError("Missing user data directory".into()))?
                    .display()
            ))
            .arg(format!(
                "--profile-directory={}",
                c.path.file_name().unwrap_or_default().to_string_lossy()
            ));
    }
    process.spawn()?;
    Ok(())
}
pub(crate) fn running(c: &Connection) -> bool {
    let system = sysinfo::System::new_all();
    system
        .processes()
        .values()
        .any(|p| p.exe().and_then(|p| p.canonicalize().ok()).as_ref() == Some(&c.executable))
}
pub(crate) fn normal_close(c: &Connection) -> Result<()> {
    if !running(c) {
        return Ok(());
    }
    #[cfg(windows)]
    {
        let script="$target=$env:BROWSER_BRIDGE_CLOSE_EXE;Get-Process | Where-Object { try { $_.Path -eq $target } catch { $false } } | ForEach-Object { if ($_.MainWindowHandle -ne 0) { [void]$_.CloseMainWindow() } }";
        let status = Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command", script])
            .env("BROWSER_BRIDGE_CLOSE_EXE", &c.executable)
            .status()?;
        if !status.success() {
            return fail("Normal browser close failed; close the selected browser and Resume");
        };
        for _ in 0..40 {
            if !running(c) {
                return Ok(());
            }
            std::thread::sleep(std::time::Duration::from_millis(250));
        }
    }
    fail("Close the selected browser normally, resolve any unsaved-work prompts, then Resume. Browser Bridge will never force-quit it.")
}
