//! Private, durable desktop boundary. Native messages never select paths or start migrations.
mod platform;
mod sessions;
mod transfer;
use fs2::FileExt;
pub use platform::{
    browser_available, discover_profiles, install_host, observe_caller,
    prepare_connector_installation,
};
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
pub const CHROMIUM_ORIGIN: &str = "chrome-extension://gagbnkkjaiikbencmbaiancdbigcjlhd/";
pub const FIREFOX_ORIGIN: &str = "connector@browser-bridge.local";
pub const HOST: &str = "local.browserbridge.connector";
pub const FRAME_LIMIT: usize = 12 * 1024 * 1024;
pub const COMMAND_LIMIT: usize = 700_000;
#[derive(Debug)]
pub struct EngineError(pub String);
impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for EngineError {}
impl From<std::io::Error> for EngineError {
    fn from(e: std::io::Error) -> Self {
        Self(e.to_string())
    }
}
impl From<serde_json::Error> for EngineError {
    fn from(e: serde_json::Error) -> Self {
        Self(e.to_string())
    }
}
pub type Result<T> = std::result::Result<T, EngineError>;
fn fail<T>(message: &str) -> Result<T> {
    Err(EngineError(message.into()))
}
pub fn default_root() -> PathBuf {
    std::env::var_os("BROWSER_BRIDGE_DESKTOP_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            dirs::data_local_dir()
                .unwrap_or_else(std::env::temp_dir)
                .join("BrowserBridgeDesktop")
        })
}
pub(crate) fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn id() -> String {
    Uuid::new_v4().to_string()
}
fn field<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str()
        .ok_or_else(|| EngineError(format!("Missing {k}")))
}
#[derive(Clone, Debug)]
pub struct Caller {
    pub browser: String,
    pub executable: PathBuf,
    pub version: String,
    pub origin: String,
}
#[derive(Default, Serialize, Deserialize)]
pub(crate) struct State {
    pub pairs: Vec<Pair>,
    pub connections: Vec<Connection>,
    pub jobs: Vec<Job>,
    pub receipts: Vec<Value>,
    #[serde(default)]
    pub sessions: Vec<Value>,
}
#[derive(Serialize, Deserialize)]
pub(crate) struct Pair {
    code: String,
    browser: String,
    path: PathBuf,
    expires: u64,
}
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Connection {
    pub id: String,
    pub browser: String,
    pub label: String,
    pub path: PathBuf,
    pub profile_id: String,
    secret: String,
    pub executable: PathBuf,
    pub version: String,
    pub last_seen: u64,
    pub capabilities: Vec<String>,
}
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Job {
    pub id: String,
    pub connection: String,
    pub operation: String,
    pub payload: Value,
    pub claimed: bool,
    pub result: Option<Value>,
    #[serde(default)]
    pub export_used: bool,
    #[serde(default)]
    pub created_at: u64,
}
#[derive(Clone)]
pub struct Engine {
    pub(crate) root: Arc<PathBuf>,
    resources: Arc<PathBuf>,
}
impl Engine {
    pub fn new(root: PathBuf, resources: PathBuf) -> Result<Self> {
        private_directory(&root)?;
        Ok(Self {
            root: Arc::new(root.canonicalize()?),
            resources: Arc::new(resources),
        })
    }
    pub(crate) fn transaction<T>(&self, action: impl FnOnce(&mut State) -> Result<T>) -> Result<T> {
        let lock = open_private(&self.root.join("state.lock"))?;
        lock.lock_exclusive()?;
        let path = self.root.join("state.json");
        let mut state: State = if path.exists() {
            check_regular(&path)?;
            if fs::metadata(&path)?.len() > 128 * 1024 * 1024 {
                return fail("State exceeds safety limit");
            };
            serde_json::from_slice(&fs::read(&path)?)?
        } else {
            State::default()
        };
        let result = action(&mut state)?;
        atomic_json(&path, &serde_json::to_value(state)?)?;
        Ok(result)
    }
    pub fn dispatch(&self, request: Value) -> Result<Value> {
        match field(&request,"command")?{
 command if command.starts_with("sessions.")=>self.sessions_dispatch(&request),
 "status"=>self.transaction(|s|Ok(json!({"platform":std::env::consts::OS,"architecture":std::env::consts::ARCH,"browsers":platform::discover(),"connections":s.connections.iter().map(redacted_connection).collect::<Vec<_>>(),"receipts":s.receipts.iter().map(transfer::redact_receipt).collect::<Vec<_>>(),"warnings":["Automatic routes await real platform acceptance. Guided packages preserve portable data; browser-specific features require guided setup."]}))),
 "discover"=>Ok(json!({"browsers":platform::discover()})),
 "pair"=>{let browser=field(&request,"browser")?.to_string();platform::validate_browser(&browser)?;let path=PathBuf::from(field(&request,"profilePath")?);validate_tree(&path)?;let path=path.canonicalize()?;self.transaction(|s|{s.pairs.retain(|p|p.expires>now());let code=id().replace('-',"")[..10].to_uppercase();let expires=now()+600;s.pairs.push(Pair{code:code.clone(),browser,path,expires});Ok(json!({"code":code,"expires":expires,"notice":"Confirm this connector belongs to the selected filesystem profile. Public browser APIs cannot establish that association."}))})},
 "installConnector"=>{let browser=field(&request,"browser")?;let host=self.resources.join(if cfg!(windows){"bridge-host.exe"}else{"bridge-host"});let host=if host.is_file(){host}else{std::env::current_exe()?.parent().ok_or_else(||EngineError("Missing executable directory".into()))?.join(if cfg!(windows){"bridge-host.exe"}else{"bridge-host"})};platform::install_host_at(browser,&host,&self.resources.join("Connector"),&self.root)},
 "plan"=>self.plan(&request),"buildGuidedPackage"=>self.guided(&request),
 "transfer"=>fail("This platform/browser pair has not passed automatic acceptance. Choose Build guided package; no browser data has been changed."),
 "resume"|"rollback"|"cancel"=>self.recover(&request),
 _=>fail("Unknown desktop command")}
    }
    pub fn native_dispatch(&self, caller: &Caller, request: Value) -> Result<Value> {
        platform::validate_browser(&caller.browser)?;
        let firefox = matches!(caller.browser.as_str(), "firefox" | "zen");
        if caller.origin
            != if firefox {
                FIREFOX_ORIGIN
            } else {
                CHROMIUM_ORIGIN
            }
        {
            return fail("Extension origin is not allowed");
        };
        if serde_json::to_vec(&request)?.len() > FRAME_LIMIT {
            return fail("Native request exceeds limit");
        };
        let action = field(&request, "action")?;
        self.transaction(|s|{if action=="pair"{let code=field(&request,"code")?;let profile_id=field(&request,"profileID")?;Uuid::parse_str(profile_id).map_err(|_|EngineError("Invalid connector profile identity".into()))?;let at=s.pairs.iter().position(|p|p.expires>now()&&p.code==code&&p.browser==caller.browser).ok_or_else(||EngineError("Pairing expired or browser identity differs".into()))?;let pair=s.pairs.remove(at);if s.connections.iter().any(|c|c.profile_id==profile_id&&c.path!=pair.path){return fail("Connector is already associated with another profile")};s.connections.retain(|c|c.path!=pair.path||c.browser!=pair.browser);let connection=Connection{id:id(),browser:caller.browser.clone(),label:request["label"].as_str().unwrap_or("Connected profile").chars().take(100).collect(),path:pair.path,profile_id:profile_id.into(),secret:format!("{}{}",id(),id()),executable:caller.executable.clone(),version:caller.version.clone(),last_seen:now(),capabilities:vec![]};let reply=json!({"ok":true,"browser":connection.browser,"connectionID":connection.id,"secret":connection.secret});s.connections.push(connection);return Ok(reply)}let connection=s.connections.iter_mut().find(|c|Some(c.id.as_str())==request["connectionID"].as_str()).ok_or_else(||EngineError("Unknown connection; pair again".into()))?;if Some(connection.secret.as_str())!=request["secret"].as_str()||Some(connection.profile_id.as_str())!=request["profileID"].as_str()||connection.browser!=caller.browser||connection.executable!=caller.executable{return fail("Connection authentication failed")};connection.last_seen=now();connection.version=caller.version.clone();let connection_id=connection.id.clone();let browser=connection.browser.clone();match action{"poll"=>{connection.capabilities=request["capabilities"].as_array().into_iter().flatten().filter_map(Value::as_str).filter(|c|["bookmarks","tabs","history","groups"].contains(c)).map(String::from).collect();if let Some(job)=s.jobs.iter_mut().find(|j|j.connection==connection_id&&j.result.is_none()){job.claimed=true;Ok(json!({"ok":true,"browser":browser,"job":{"id":job.id,"operation":job.operation,"payload":job.payload}}))}else{Ok(json!({"ok":true,"browser":browser}))}},"complete"=>{let job_id=field(&request,"jobID")?;let result=request.get("result").ok_or_else(||EngineError("Missing result".into()))?;if serde_json::to_vec(result)?.len()>8*1024*1024{return fail("Capture exceeds 8 MiB; use the browser's HTML export")};let job=s.jobs.iter_mut().find(|j|j.id==job_id&&j.connection==connection_id).ok_or_else(||EngineError("Unknown job".into()))?;let sanitized=sessions::sanitize_result(&job.operation,result)?;let result=&sanitized;
                if !job.claimed{return fail("Job was not claimed")};if let Some(old)=&job.result{if old!=result{return fail("Completed job cannot change")}}else{job.result=Some(result.clone())};Ok(json!({"ok":true}))},_=>fail("Unknown native operation")}})
    }
    pub(crate) fn enqueue(
        &self,
        connection: &str,
        operation: &str,
        payload: Value,
    ) -> Result<String> {
        if !["capture", "import", "verify", "rollback"].contains(&operation)
            && !sessions::operation(operation)
        {
            return fail("Unsupported operation");
        };
        if serde_json::to_vec(&payload)?.len() > COMMAND_LIMIT {
            return fail("Command exceeds safe browser frame size; use a guided package");
        };
        self.transaction(|s| {
            if !s.connections.iter().any(|c| c.id == connection) {
                return fail("Unknown connection");
            };
            if let Some(job) = s
                .jobs
                .iter()
                .find(|j| j.connection == connection && j.result.is_none())
            {
                if job.operation == operation && job.payload == payload {
                    return Ok(job.id.clone());
                }
                return fail(
                    "An earlier connector operation is still pending; resume or cancel it first",
                );
            };
            let job = Job {
                id: id(),
                connection: connection.into(),
                operation: operation.into(),
                payload,
                claimed: false,
                result: None,
                export_used: false,
                created_at: now(),
            };
            let result = job.id.clone();
            s.jobs.push(job);
            Ok(result)
        })
    }
    /// Trusted local validation seam; never reachable through desktop/native JSON commands.
    pub fn enqueue_validation(
        &self,
        connection: &str,
        operation: &str,
        payload: Value,
        disposable_root: &Path,
    ) -> Result<String> {
        self.validate_disposable(disposable_root)?;
        self.enqueue(connection, operation, payload)
    }
    pub(crate) fn validate_disposable(&self, root: &Path) -> Result<()> {
        let root = root.canonicalize()?;
        if self.root.as_path() == root || !self.root.starts_with(&root) {
            return fail("State must be below the explicit disposable root");
        };
        self.transaction(|s| {
            if s.connections.iter().any(|c| !c.path.starts_with(&root)) {
                return fail("All connected profiles must be below the disposable root");
            };
            Ok(())
        })
    }
}
fn redacted_connection(c: &Connection) -> Value {
    json!({"id":c.id,"browser":c.browser,"label":c.label,"profilePath":c.path,"connected":now().saturating_sub(c.last_seen)<20,"capabilities":c.capabilities,"version":c.version,"readiness":"guided"})
}
pub(crate) fn check_regular(path: &Path) -> Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if meta.file_type().is_symlink() || !meta.is_file() {
        return fail("Expected a regular file, not a symlink");
    };
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if meta.file_attributes() & 0x400 != 0 {
            return fail("Reparse points are not allowed");
        }
    }
    Ok(())
}
pub(crate) fn validate_tree(path: &Path) -> Result<()> {
    let mut cursor = PathBuf::new();
    for component in path.components() {
        cursor.push(component);
        if let Ok(meta) = fs::symlink_metadata(&cursor) {
            if meta.file_type().is_symlink() {
                return fail("Symlink paths are not supported; select the real directory");
            };
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if meta.file_attributes() & 0x400 != 0 {
                    return fail("Reparse points are not supported");
                }
            }
        }
    }
    if !path.is_dir() {
        return fail("Select an existing directory");
    };
    Ok(())
}
pub(crate) fn private_directory(path: &Path) -> Result<()> {
    if path.exists() {
        validate_tree(path)?
    } else {
        if let Some(parent) = path.parent() {
            if !parent.exists() {
                private_directory(parent)?
            } else {
                validate_tree(parent)?
            }
        }
        fs::create_dir(path)?
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    #[cfg(windows)]
    platform::private_acl(path)?;
    Ok(())
}
fn open_private(path: &Path) -> Result<File> {
    if path.exists() {
        check_regular(path)?
    }
    let mut opts = OpenOptions::new();
    opts.create(true).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    Ok(opts.open(path)?)
}
pub(crate) fn atomic_json(path: &Path, value: &Value) -> Result<()> {
    atomic_bytes(path, &serde_json::to_vec_pretty(value)?)
}
pub(crate) fn atomic_bytes(path: &Path, bytes: &[u8]) -> Result<()> {
    if path.exists() {
        check_regular(path)?
    }
    let parent = path
        .parent()
        .ok_or_else(|| EngineError("Missing parent".into()))?;
    validate_tree(parent)?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        temporary
            .as_file()
            .set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    temporary.write_all(bytes)?;
    temporary.as_file().sync_all()?;
    temporary
        .persist(path)
        .map_err(|e| EngineError(e.to_string()))?;
    Ok(())
}
