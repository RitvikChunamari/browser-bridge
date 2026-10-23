#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use bridge_engine::{Engine, default_root};
use bridge_sensitive::CredentialManager;
use serde_json::{json, Value};
use tauri::{Manager, State};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

#[tauri::command]
async fn engine(request: Value, state: State<'_, Engine>, credentials: State<'_, CredentialManager>) -> Result<Value, String> {
    let name=request.get("command").and_then(Value::as_str).unwrap_or("");
    if ["credentials.protect", "credentials.list", "credentials.stage", "credentials.cleanup", "credentials.confirmImport"].contains(&name) {
        let manager=credentials.inner().clone();
        return tauri::async_runtime::spawn_blocking(move || manager.dispatch(request).map_err(|e|e.to_string())).await.map_err(|_|"The sensitive operation stopped. Reopen Credentials to review temporary file cleanup.".to_string())?;
    }
    let allowed = ["status", "discover", "installConnector", "pair", "plan", "buildGuidedPackage", "transfer", "resume", "rollback", "cancel", "sessions.plan", "sessions.start", "sessions.status", "sessions.retry", "sessions.confirm", "sessions.cleanup"];
    let name=request.get("command").and_then(Value::as_str).unwrap_or("");
    if !allowed.contains(&name) { return Err("This operation is unavailable. Update the app or use the documented browser flow.".into()); }
    let engine=state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || engine.dispatch(request).map_err(|e|e.to_string())).await.map_err(|_|"The local operation stopped unexpectedly. Refresh receipts before retrying.".to_string())?
}
#[tauri::command]
async fn choose_path(app: tauri::AppHandle, purpose: String) -> Result<Option<String>, String> {
    if !["profile", "backup", "credential", "capture"].contains(&purpose.as_str()) { return Err("Unknown file selection.".into()); }
    tauri::async_runtime::spawn_blocking(move || {
        let picker=app.dialog().file();
        let selected=match purpose.as_str() {
            "credential"=>picker.set_title("Choose a password CSV export").add_filter("Password CSV", &["csv"]).blocking_pick_file(),
            "capture"=>picker.set_title("Choose a browser capture or bookmarks HTML").add_filter("Portable browser data", &["json","html","htm"]).blocking_pick_file(),
            "backup"=>picker.set_title("Choose a private backup folder").blocking_pick_folder(),
            _=>picker.set_title("Choose the exact browser profile folder").blocking_pick_folder(),
        };
        selected.map(|p|p.into_path().map(|p|p.to_string_lossy().into_owned()).map_err(|_|"Choose a local filesystem path.".to_string())).transpose()
    }).await.map_err(|_|"The file picker closed unexpectedly.".to_string())?
}
#[tauri::command]
fn open_reference(app: tauri::AppHandle, reference: String) -> Result<(), String> {
    let url=match reference.as_str() {
        "setup"=>"https://github.com/RitvikChunamari/browser-bridge/blob/main/docs/connector-setup.md",
        "credentials"=>"https://github.com/RitvikChunamari/browser-bridge/blob/main/docs/sensitive-transfer.md",
        "support"=>"https://ritvikchunamari.github.io/browser-bridge/#support",
        _=>return Err("Unknown reference.".into()),
    };
    app.opener().open_url(url,None::<&str>).map_err(|_|"Could not open your default browser. Open the setup guide from the project website.".into())
}
fn main() {
    tauri::Builder::default().plugin(tauri_plugin_dialog::init()).plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let resources=app.path().resource_dir()?;
            let credentials=CredentialManager::new(default_root().join("Credentials"))?;
            let expiry=credentials.clone();
            std::thread::spawn(move || loop {
                std::thread::sleep(std::time::Duration::from_secs(30));
                // list performs expiry cleanup. Never log replies or sensitive errors.
                let _=expiry.dispatch(json!({"command":"list"}));
            });
            app.manage(credentials);
            app.manage(Engine::new(default_root(),resources)?);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![engine,choose_path,open_reference])
        .build(tauri::generate_context!()).expect("Browser Bridge could not start")
        .run(|app,event| {
            if matches!(event,tauri::RunEvent::Exit) {
                let manager=app.state::<CredentialManager>();
                if let Ok(status)=manager.dispatch(json!({"command":"list"})) {
                    for stage in status["stages"].as_array().into_iter().flatten() {
                        let _=manager.dispatch(json!({"command":"cleanup","stageId":stage["stageId"]}));
                    }
                }
            }
        });
}
