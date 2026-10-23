use bridge_engine::{browser_available, discover_profiles, Caller, Engine, CHROMIUM_ORIGIN};
use serde_json::{json, Value};
fn paired(root: &std::path::Path) -> (Engine, Caller, Value) {
    let profile = root.join("source");
    std::fs::create_dir(&profile).unwrap();
    let engine = Engine::new(
        root.join("state"),
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .nth(3)
            .unwrap()
            .join("Resources"),
    )
    .unwrap();
    let code = engine
        .dispatch(json!({"command":"pair","browser":"chrome","profilePath":profile}))
        .unwrap();
    let caller = Caller {
        browser: "chrome".into(),
        executable: root.join("fixture"),
        version: "fixture".into(),
        origin: CHROMIUM_ORIGIN.into(),
    };
    let auth=engine.native_dispatch(&caller,json!({"action":"pair","code":code["code"],"profileID":"90a0bfda-5665-4322-a2be-8d39c8cdbd01"})).unwrap();
    (engine, caller, auth)
}
fn capture(engine: &Engine, caller: &Caller, auth: &Value, root: &std::path::Path) {
    let id = engine
        .enqueue_validation(
            auth["connectionID"].as_str().unwrap(),
            "capture",
            json!({"guidedExport":true,"history":false}),
            root,
        )
        .unwrap();
    let mut request = json!({"action":"poll","connectionID":auth["connectionID"],"secret":auth["secret"],"profileID":"90a0bfda-5665-4322-a2be-8d39c8cdbd01"});
    engine.native_dispatch(caller, request.clone()).unwrap();
    request["action"] = json!("complete");
    request["jobID"] = json!(id);
    request["result"] = json!({"ok":true,"capture":{"schema":1,"format":"browser-bridge-capture","snapshot":{"spaces":[{"id":"w","name":"Private window"}],"folders":[{"id":"g","name":"Private group","spaceID":"w"}],"tabs":[{"id":"t","url":"https://tab.test/","pinned":true,"folderID":"g","spaceID":"w"}],"bookmarks":[{"id":1,"parent":0,"type":1,"title":"Saved","url":"https://saved.test/"}],"history":[{"url":"https://history.test/"}]}}});
    engine.native_dispatch(caller, request).unwrap();
}
#[test]
fn unavailable_platforms_and_root_profiles_are_reported_honestly() {
    assert!(!browser_available("safari", "linux"));
    assert!(browser_available("dia", "windows"));
    assert!(!browser_available("dia", "linux"));
    assert!(!browser_available("arc", "linux"));
    assert!(browser_available("arc", "windows"));
    let raw = tempfile::tempdir().unwrap();
    std::fs::write(raw.path().join("Preferences"), "{}").unwrap();
    let profiles = discover_profiles("opera", raw.path());
    assert_eq!(profiles.len(), 1);
    assert_eq!(profiles[0]["path"], json!(raw.path()));
}
#[test]
fn guided_artifacts_respect_selected_categories() {
    let raw = tempfile::tempdir().unwrap();
    let root = raw.path().canonicalize().unwrap();
    let (engine, caller, auth) = paired(&root);
    capture(&engine, &caller, &auth, &root);
    let out=engine.dispatch(json!({"command":"buildGuidedPackage","sourceId":auth["connectionID"],"backupDirectory":root.join("exports"),"options":{"bookmarks":true,"tabs":false,"groups":false,"history":false}}));
    assert!(out.is_ok(), "{out:?}");
    let path = std::path::PathBuf::from(out.unwrap()["packagePath"].as_str().unwrap());
    let artifact: Value =
        serde_json::from_slice(&std::fs::read(path.join("capture.json")).unwrap()).unwrap();
    assert_eq!(artifact["snapshot"]["tabs"], json!([]));
    assert_eq!(artifact["snapshot"]["history"], json!([]));
    assert_eq!(artifact["snapshot"]["folders"], json!([]));
    let html = std::fs::read_to_string(path.join("Bookmarks.html")).unwrap();
    assert!(!html.contains("tab.test"));
    assert!(html.contains("saved.test"));
    let imported: Value =
        serde_json::from_slice(&std::fs::read(path.join("Importer/data.json")).unwrap()).unwrap();
    assert_eq!(imported["snapshot"]["tabs"], json!([]));
    let archives = std::fs::read_dir(root.join("state/CaptureArchive")).unwrap();
    let archived: Value = serde_json::from_slice(
        &std::fs::read(archives.into_iter().next().unwrap().unwrap().path()).unwrap(),
    )
    .unwrap();
    assert_eq!(archived["snapshot"]["tabs"].as_array().unwrap().len(), 1);
}
#[cfg(unix)]
#[test]
fn rejected_backup_location_does_not_change_source_permissions() {
    use std::os::unix::fs::PermissionsExt;
    let raw = tempfile::tempdir().unwrap();
    let root = raw.path().canonicalize().unwrap();
    let (engine, caller, auth) = paired(&root);
    capture(&engine, &caller, &auth, &root);
    let source = root.join("source");
    std::fs::set_permissions(&source, std::fs::Permissions::from_mode(0o755)).unwrap();
    let before = std::fs::metadata(&source).unwrap().permissions().mode();
    let result=engine.dispatch(json!({"command":"buildGuidedPackage","sourceId":auth["connectionID"],"backupDirectory":source,"options":{"history":false}}));
    assert!(result.is_err());
    assert_eq!(
        std::fs::metadata(&source).unwrap().permissions().mode(),
        before
    );
}

#[test]
fn tabs_only_export_excludes_saved_bookmarks_and_groups() {
    let raw = tempfile::tempdir().unwrap();
    let root = raw.path().canonicalize().unwrap();
    let (engine, caller, auth) = paired(&root);
    capture(&engine, &caller, &auth, &root);
    let out=engine.dispatch(json!({"command":"buildGuidedPackage","sourceId":auth["connectionID"],"backupDirectory":root.join("exports"),"options":{"bookmarks":false,"tabs":true,"groups":false,"history":false}})).unwrap();
    let path = std::path::Path::new(out["packagePath"].as_str().unwrap());
    let artifact: Value =
        serde_json::from_slice(&std::fs::read(path.join("Importer/data.json")).unwrap()).unwrap();
    assert_eq!(artifact["snapshot"]["bookmarks"], json!([]));
    assert_eq!(artifact["snapshot"]["folders"], json!([]));
    assert_eq!(artifact["snapshot"]["tabs"][0]["pinned"], true);
    assert!(artifact["snapshot"]["tabs"][0]["folderID"].is_null());
    let html = std::fs::read_to_string(path.join("Bookmarks.html")).unwrap();
    assert!(html.contains("tab.test"));
    assert!(!html.contains("saved.test"));
}

#[cfg(unix)]
#[test]
fn valid_existing_backup_parent_keeps_its_permissions() {
    use std::os::unix::fs::PermissionsExt;
    let raw = tempfile::tempdir().unwrap();
    let root = raw.path().canonicalize().unwrap();
    let (engine, caller, auth) = paired(&root);
    capture(&engine, &caller, &auth, &root);
    let base = root.join("shared-exports");
    std::fs::create_dir(&base).unwrap();
    std::fs::set_permissions(&base, std::fs::Permissions::from_mode(0o755)).unwrap();
    let before = std::fs::metadata(&base).unwrap().permissions().mode();
    engine.dispatch(json!({"command":"buildGuidedPackage","sourceId":auth["connectionID"],"backupDirectory":base,"options":{"history":false}})).unwrap();
    assert_eq!(
        std::fs::metadata(&base).unwrap().permissions().mode(),
        before
    );
}

#[test]
fn unsupported_connector_is_rejected_before_installation_writes() {
    let raw = tempfile::tempdir().unwrap();
    let root = raw.path().canonicalize().unwrap();
    let engine = Engine::new(root.join("state"), root.join("resources")).unwrap();
    assert!(engine
        .dispatch(json!({"command":"installConnector","browser":"helium"}))
        .is_err());
    assert!(!root.join("state/Connectors").exists());
    assert!(!root.join("state/NativeMessagingHosts").exists());
}
