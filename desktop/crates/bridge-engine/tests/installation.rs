use bridge_engine::prepare_connector_installation;
use serde_json::Value;
#[test]
fn firefox_and_chromium_installations_use_private_variants_and_independent_host_manifests() {
    let raw = tempfile::tempdir().unwrap();
    let root = raw.path().canonicalize().unwrap();
    let host = root.join("bridge-host");
    std::fs::write(&host, "synthetic host").unwrap();
    let resources = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .unwrap()
        .join("Resources/Connector");
    let state = root.join("state");
    let chrome = prepare_connector_installation("chrome", &host, &resources, &state).unwrap();
    let firefox = prepare_connector_installation("firefox", &host, &resources, &state).unwrap();
    let zen = prepare_connector_installation("zen", &host, &resources, &state).unwrap();
    fn read(path: &Value) -> Value {
        serde_json::from_slice(&std::fs::read(path.as_str().unwrap()).unwrap()).unwrap()
    }
    let chromium_manifest = read(&chrome["manifestPath"]);
    let firefox_manifest = read(&firefox["manifestPath"]);
    assert_ne!(chrome["manifestPath"], firefox["manifestPath"]);
    assert_ne!(firefox["manifestPath"], zen["manifestPath"]);
    assert!(chromium_manifest["allowed_origins"].is_array());
    assert!(chromium_manifest["allowed_extensions"].is_null());
    assert!(firefox_manifest["allowed_extensions"].is_array());
    assert!(firefox_manifest["allowed_origins"].is_null());
    let connector = std::path::Path::new(firefox["connectorPath"].as_str().unwrap());
    assert!(connector.starts_with(&state));
    assert_ne!(connector, resources);
    let variant: Value =
        serde_json::from_slice(&std::fs::read(connector.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(
        variant["browser_specific_settings"]["gecko"]["id"],
        "connector@browser-bridge.local"
    );
    assert!(variant["background"]["scripts"].is_array());
    assert!(variant["key"].is_null());
    let original: Value =
        serde_json::from_slice(&std::fs::read(resources.join("manifest.json")).unwrap()).unwrap();
    assert!(original["key"].is_string());
    assert_eq!(read(&chrome["manifestPath"]), chromium_manifest);
}
