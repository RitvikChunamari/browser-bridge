//! Local, consented password CSV staging. Never decrypts browser stores or claims verified import.
use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::{
    aead::{Aead, KeyInit, Payload},
    XChaCha20Poly1305, XNonce,
};
use fs2::FileExt;
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

const CSV_LIMIT: u64 = 8 * 1024 * 1024;
const VAULT_LIMIT: u64 = 48 * 1024 * 1024;
const STAGE_LIFETIME: u64 = 15 * 60;
#[derive(Debug)]
pub struct CredentialError {
    pub code: &'static str,
    pub message: &'static str,
}
impl std::fmt::Display for CredentialError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.message)
    }
}
impl std::error::Error for CredentialError {}
pub type Result<T> = std::result::Result<T, CredentialError>;
fn err(code: &'static str, message: &'static str) -> CredentialError {
    CredentialError { code, message }
}
fn storage(_: impl std::fmt::Display) -> CredentialError {
    err("storage", "Cannot access protected credential storage. Check access and retry; source files are unchanged.")
}
fn invalid() -> CredentialError {
    err(
        "invalid_request",
        "Invalid credential request. Choose a supported action and valid identifiers.",
    )
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[derive(Clone)]
pub struct CredentialManager {
    root: Arc<PathBuf>,
    clock: Arc<dyn Fn() -> u64 + Send + Sync>,
}
#[derive(Serialize, Deserialize)]
struct Vault {
    schema: u32,
    id: String,
    created: u64,
    count: usize,
    salt: [u8; 16],
    nonce: [u8; 24],
    ciphertext: Vec<u8>,
}
#[derive(Serialize, Deserialize)]
struct Stage {
    schema: u32,
    id: String,
    vault_id: String,
    expires: u64,
}

impl CredentialManager {
    pub fn new(root: PathBuf) -> Result<Self> {
        Self::with_clock(root, Arc::new(now))
    }
    /// Injectable system-clock boundary for deterministic expiry verification; never exposed to the renderer.
    pub fn with_clock(root: PathBuf, clock: Arc<dyn Fn() -> u64 + Send + Sync>) -> Result<Self> {
        private_dir(&root)?;
        private_dir(&root.join("vaults"))?;
        private_dir(&root.join("stages"))?;
        let manager = Self {
            root: Arc::new(root.canonicalize().map_err(storage)?),
            clock,
        };
        let _lock = manager.lock()?;
        manager.expire()?;
        Ok(manager)
    }
    /// Passphrases must come directly from an explicit sensitive UI step, never a durable queue.
    pub fn dispatch(&self, mut request: Value) -> Result<Value> {
        let result = self.dispatch_inner(&mut request);
        if let Some(Value::String(passphrase)) = request.get_mut("passphrase") {
            passphrase.zeroize();
        }
        result
    }
    fn dispatch_inner(&self, request: &mut Value) -> Result<Value> {
        let command = request["command"]
            .as_str()
            .ok_or_else(invalid)?
            .trim_start_matches("credentials.")
            .to_owned();
        let _lock = self.lock()?;
        self.expire()?;
        match command.as_str() {
            "protect" => {
                consent(request)?;
                let path = PathBuf::from(request["path"].as_str().ok_or_else(invalid)?);
                let secret = secret(request)?;
                let csv = read_private_input(&path, CSV_LIMIT)?;
                let count = validate_csv(&csv)?;
                let id = Uuid::new_v4().to_string();
                let mut vault = Vault {
                    schema: 1,
                    id: id.clone(),
                    created: (self.clock)(),
                    count,
                    salt: [0; 16],
                    nonce: [0; 24],
                    ciphertext: vec![],
                };
                OsRng.fill_bytes(&mut vault.salt);
                OsRng.fill_bytes(&mut vault.nonce);
                let key = derive(&secret, &vault.salt)?;
                vault.ciphertext = XChaCha20Poly1305::new_from_slice(&key[..])
                    .map_err(storage)?
                    .encrypt(
                        XNonce::from_slice(&vault.nonce),
                        Payload {
                            msg: &csv,
                            aad: &aad(&vault),
                        },
                    )
                    .map_err(|_| {
                        err(
                            "encryption",
                            "Cannot protect credentials. Retry with a new vault.",
                        )
                    })?;
                atomic_json(&self.vault_path(&id), &vault)?;
                Ok(
                    json!({"vaultId":id,"count":count,"createdAt":vault.created,"encrypted":true,"sourcePreserved":true,"notice":"The original browser export is unchanged. Handle its plaintext file separately."}),
                )
            }
            "list" => {
                let mut vaults = Vec::new();
                for entry in fs::read_dir(self.root.join("vaults")).map_err(storage)? {
                    let path = entry.map_err(storage)?.path();
                    let v: Vault = read_json(&path, VAULT_LIMIT)?;
                    validate_vault(&v)?;
                    vaults.push(json!({"vaultId":v.id,"count":v.count,"createdAt":v.created}));
                }
                let stages = self
                    .stages()?
                    .into_iter()
                    .map(|s| json!({"stageId":s.id,"vaultId":s.vault_id,"expiresAt":s.expires}))
                    .collect::<Vec<_>>();
                Ok(
                    json!({"vaults":vaults,"stages":stages,"notice":"Import outcomes are user-confirmed, not independently verified."}),
                )
            }
            "stage" => {
                consent(request)?;
                let id = identifier(request, "vaultId")?;
                let secret = secret(request)?;
                let vault: Vault = read_json(&self.vault_path(&id), VAULT_LIMIT)?;
                validate_vault(&vault)?;
                if vault.id != id {
                    return Err(invalid());
                }
                let key = derive(&secret, &vault.salt)?;
                let csv = Zeroizing::new(XChaCha20Poly1305::new_from_slice(&key[..]).map_err(storage)?
                    .decrypt(XNonce::from_slice(&vault.nonce), Payload { msg:&vault.ciphertext, aad:&aad(&vault) })
                    .map_err(|_| err("unlock_failed", "Cannot unlock the vault. Check its passphrase; changed or damaged vaults cannot be opened."))?);
                validate_csv(&csv)?;
                let stage = Stage {
                    schema: 1,
                    id: Uuid::new_v4().to_string(),
                    vault_id: id,
                    expires: (self.clock)() + STAGE_LIFETIME,
                };
                atomic_json(&self.stage_record(&stage.id), &stage)?;
                let path = self.stage_csv(&stage.id);
                if let Err(error) = stage_bytes(&path, &csv) {
                    let _ = fs::remove_file(&path);
                    let _ = fs::remove_file(self.stage_record(&stage.id));
                    return Err(error);
                }
                Ok(
                    json!({"stageId":stage.id,"vaultId":stage.vault_id,"temporaryPath":path,"expiresAt":stage.expires,"sensitive":true,"notice":"Use the destination browser's password importer and complete its authentication prompts. This plaintext file becomes eligible for cleanup after 15 minutes and is removed on the next app action or startup; use immediate cleanup when finished."}),
                )
            }
            "cleanup" | "confirmImport" => {
                let id = identifier(request, "stageId")?;
                if command == "confirmImport" && request["confirmed"] != true {
                    return Err(err(
                        "confirmation_required",
                        "Confirm the browser-reported import outcome before recording it.",
                    ));
                }
                let stage: Stage = read_json(&self.stage_record(&id), 4096)?;
                if stage.id != id || stage.schema != 1 {
                    return Err(invalid());
                }
                self.remove_stage(&stage)?;
                Ok(
                    json!({"stageId":id,"cleaned":true,"outcome":if command=="confirmImport" {"user-confirmed"} else {"cancelled-or-cleaned"},"verified":false,"sourcePreserved":true}),
                )
            }
            _ => Err(invalid()),
        }
    }
    fn lock(&self) -> Result<File> {
        let file = open_file(&self.root.join("credentials.lock"), true)?;
        file.lock_exclusive().map_err(storage)?;
        Ok(file)
    }
    fn vault_path(&self, id: &str) -> PathBuf {
        self.root.join("vaults").join(format!("{id}.json"))
    }
    fn stage_record(&self, id: &str) -> PathBuf {
        self.root.join("stages").join(format!("{id}.json"))
    }
    fn stage_csv(&self, id: &str) -> PathBuf {
        self.root.join("stages").join(format!("{id}.csv"))
    }
    fn stages(&self) -> Result<Vec<Stage>> {
        let mut result = vec![];
        for item in fs::read_dir(self.root.join("stages")).map_err(storage)? {
            let path = item.map_err(storage)?.path();
            if path.extension().and_then(|s| s.to_str()) != Some("json") {
                continue;
            }
            let stage: Stage = read_json(&path, 4096)?;
            if stage.schema != 1
                || Uuid::parse_str(&stage.id).is_err()
                || Uuid::parse_str(&stage.vault_id).is_err()
                || self.stage_record(&stage.id) != path
            {
                return Err(invalid());
            }
            result.push(stage);
        }
        Ok(result)
    }
    fn remove_stage(&self, stage: &Stage) -> Result<()> {
        for path in [self.stage_csv(&stage.id), self.stage_record(&stage.id)] {
            if path.exists() {
                check_regular(&path)?;
                fs::remove_file(path).map_err(storage)?;
            }
        }
        Ok(())
    }
    fn expire(&self) -> Result<()> {
        for stage in self.stages()? {
            if stage.expires <= (self.clock)() {
                self.remove_stage(&stage)?;
            }
        }
        Ok(())
    }
}
fn consent(value: &Value) -> Result<()> {
    if value["consent"] == true {
        Ok(())
    } else {
        Err(err(
            "consent_required",
            "Explicit consent is required for each credential protection or import staging action.",
        ))
    }
}
fn identifier(value: &Value, key: &str) -> Result<String> {
    let s = value[key].as_str().ok_or_else(invalid)?;
    Uuid::parse_str(s).map_err(|_| invalid())?;
    Ok(s.to_owned())
}
fn secret(value: &mut Value) -> Result<Zeroizing<String>> {
    let mut raw = value
        .get_mut("passphrase")
        .map(Value::take)
        .ok_or_else(invalid)?;
    let secret = match &mut raw {
        Value::String(s) => Zeroizing::new(std::mem::take(s)),
        _ => return Err(invalid()),
    };
    if !(12..=1024).contains(&secret.len()) {
        return Err(err(
            "passphrase_required",
            "Use a vault passphrase of 12 to 1024 bytes. It is not saved by Browser Bridge.",
        ));
    }
    Ok(secret)
}
fn derive(secret: &str, salt: &[u8; 16]) -> Result<Zeroizing<[u8; 32]>> {
    let mut key = Zeroizing::new([0; 32]);
    let parameters = Params::new(65536, 3, 1, Some(32)).map_err(storage)?;
    Argon2::new(Algorithm::Argon2id, Version::V0x13, parameters)
        .hash_password_into(secret.as_bytes(), salt, &mut key[..])
        .map_err(storage)?;
    Ok(key)
}
fn aad(v: &Vault) -> Vec<u8> {
    format!(
        "browser-bridge-passwords:{}:{}:{}:{}",
        v.schema, v.id, v.created, v.count
    )
    .into_bytes()
}
fn validate_vault(v: &Vault) -> Result<()> {
    if v.schema != 1
        || Uuid::parse_str(&v.id).is_err()
        || v.ciphertext.len() > CSV_LIMIT as usize + 16
    {
        Err(err(
            "invalid_vault",
            "Unsupported or oversized credential vault.",
        ))
    } else {
        Ok(())
    }
}
fn validate_csv(bytes: &[u8]) -> Result<usize> {
    let mut reader = csv::ReaderBuilder::new().from_reader(bytes);
    let headers = reader
        .headers()
        .map_err(|_| {
            err(
                "invalid_csv",
                "Choose a browser password CSV with url, username and password columns.",
            )
        })?
        .clone();
    if !["url", "username", "password"].iter().all(|h| {
        headers
            .iter()
            .filter(|v| v.trim_start_matches('\u{feff}').eq_ignore_ascii_case(h))
            .count()
            == 1
    }) {
        return Err(err("invalid_csv","Choose a browser password CSV with url, username and password columns. Passkeys are not password CSV entries."));
    }
    let mut count = 0;
    for record in reader.records() {
        record.map_err(|_| {
            err(
                "invalid_csv",
                "The password CSV has malformed rows. Re-export it from the source browser.",
            )
        })?;
        count += 1;
        if count > 100_000 {
            return Err(err(
                "invalid_csv",
                "The password CSV exceeds the supported entry limit.",
            ));
        }
    }
    if count == 0 {
        return Err(err("invalid_csv", "The password CSV contains no entries."));
    }
    Ok(count)
}
fn validate_path(path: &Path) -> Result<()> {
    if !path.is_absolute() {
        return Err(invalid());
    }
    let mut current = PathBuf::new();
    for component in path.components() {
        if matches!(component, std::path::Component::ParentDir) {
            return Err(invalid());
        }
        current.push(component);
        if let Ok(meta) = fs::symlink_metadata(&current) {
            if meta.file_type().is_symlink() {
                return Err(err("unsafe_path","Choose a real file or directory; symbolic links are not accepted for credentials."));
            }
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if meta.file_attributes() & 0x400 != 0 {
                    return Err(err(
                        "unsafe_path",
                        "Reparse points are not accepted for credential storage.",
                    ));
                }
            }
        }
    }
    Ok(())
}
fn check_regular(path: &Path) -> Result<()> {
    validate_path(path)?;
    if !fs::symlink_metadata(path).map_err(storage)?.is_file() {
        return Err(invalid());
    }
    Ok(())
}
fn private_dir(path: &Path) -> Result<()> {
    validate_path(path)?;
    if !path.exists() {
        if let Some(p) = path.parent() {
            if !p.exists() {
                private_dir(p)?;
            }
        }
        fs::create_dir(path).map_err(storage)?;
    }
    if !path.is_dir() {
        return Err(invalid());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(storage)?;
    }
    #[cfg(windows)]
    {
        let script="$p=[Environment]::GetEnvironmentVariable('BROWSER_BRIDGE_CREDENTIAL_DIR');$sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User;$acl=New-Object System.Security.AccessControl.DirectorySecurity;$acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false);$rule=New-Object System.Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow');$acl.AddAccessRule($rule);Set-Acl -LiteralPath $p -AclObject $acl -ErrorAction Stop";
        let status = std::process::Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command", script])
            .env("BROWSER_BRIDGE_CREDENTIAL_DIR", path)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map_err(storage)?;
        if !status.success() {
            return Err(err(
                "storage",
                "Cannot establish owner-only credential storage permissions.",
            ));
        }
    }
    Ok(())
}
fn open_file(path: &Path, create: bool) -> Result<File> {
    validate_path(path)?;
    if path.exists() {
        check_regular(path)?;
    }
    let mut options = OpenOptions::new();
    options.read(true).write(create).create(create);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    options.open(path).map_err(storage)
}
fn read_private_input(path: &Path, limit: u64) -> Result<Zeroizing<Vec<u8>>> {
    let file = open_file(path, false)?;
    if file.metadata().map_err(storage)?.len() > limit {
        return Err(err(
            "oversized",
            "Credential data exceeds the supported size.",
        ));
    }
    let mut bytes = Zeroizing::new(vec![]);
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(storage)?;
    if bytes.len() as u64 > limit {
        return Err(err(
            "oversized",
            "Credential data exceeds the supported size.",
        ));
    }
    Ok(bytes)
}
fn read_json<T: for<'a> Deserialize<'a>>(path: &Path, limit: u64) -> Result<T> {
    serde_json::from_slice(&read_private_input(path, limit)?).map_err(|_| {
        err(
            "invalid_storage",
            "Credential storage is damaged or unsupported.",
        )
    })
}
fn atomic_json(path: &Path, value: &impl Serialize) -> Result<()> {
    atomic_bytes(path, &serde_json::to_vec(value).map_err(storage)?)
}
fn atomic_bytes(path: &Path, bytes: &[u8]) -> Result<()> {
    validate_path(path)?;
    if path.exists() {
        check_regular(path)?;
    }
    let parent = path.parent().ok_or_else(invalid)?;
    validate_path(parent)?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent).map_err(storage)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        temporary
            .as_file()
            .set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(storage)?;
    }
    temporary.write_all(bytes).map_err(storage)?;
    temporary.as_file().sync_all().map_err(storage)?;
    temporary.persist(path).map_err(storage)?;
    Ok(())
}

// The stage metadata is persisted first. Write plaintext only at its owned final name, so
// an interrupted write remains discoverable for expiry cleanup (no orphan plaintext tempfiles).
fn stage_bytes(path: &Path, bytes: &[u8]) -> Result<()> {
    validate_path(path)?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(path).map_err(storage)?;
    file.write_all(bytes).map_err(storage)?;
    file.sync_all().map_err(storage)?;
    Ok(())
}
