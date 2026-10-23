use bridge_sensitive::CredentialManager;
use serde_json::json;
use std::fs;

#[test]
fn user_can_protect_stage_and_confirm_import_without_modifying_original() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().canonicalize().unwrap();
    let original = root.join("original.csv");
    let csv = "url,username,password\nhttps://example.test,synthetic-user,synthetic-password\n";
    fs::write(&original, csv).unwrap();
    let manager = CredentialManager::new(root.join("credentials")).unwrap();
    let protected = manager.dispatch(json!({"command":"protect","path":original,"passphrase":"synthetic vault passphrase","consent":true})).unwrap();
    assert!(!protected.to_string().contains("synthetic-password"));
    assert_eq!(protected["count"], 1);
    let staged = manager.dispatch(json!({"command":"stage","vaultId":protected["vaultId"],"passphrase":"synthetic vault passphrase","consent":true})).unwrap();
    let path = staged["temporaryPath"].as_str().unwrap();
    assert!(fs::read_to_string(path)
        .unwrap()
        .contains("synthetic-password"));
    let denied = manager
        .dispatch(json!({"command":"confirmImport","stageId":staged["stageId"],"confirmed":false}))
        .unwrap_err();
    assert_eq!(denied.code, "confirmation_required");
    assert!(std::path::Path::new(path).exists());
    let finished = manager
        .dispatch(json!({"command":"confirmImport","stageId":staged["stageId"],"confirmed":true}))
        .unwrap();
    assert_eq!(finished["outcome"], "user-confirmed");
    assert_eq!(finished["verified"], false);
    assert!(!std::path::Path::new(path).exists());
    assert_eq!(fs::read_to_string(original).unwrap(), csv);
}

#[test]
fn interrupted_plaintext_stage_expires_on_next_startup_and_vault_survives() {
    use std::sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    };
    let home = tempfile::tempdir().unwrap();
    let root = home.path().canonicalize().unwrap();
    let original = root.join("original.csv");
    fs::write(
        &original,
        "url,username,password\nhttps://example.test,user,test-password\n",
    )
    .unwrap();
    let time = Arc::new(AtomicU64::new(1000));
    let clock = {
        let time = time.clone();
        Arc::new(move || time.load(Ordering::SeqCst))
    };
    let manager = CredentialManager::with_clock(root.join("credentials"), clock.clone()).unwrap();
    let vault=manager.dispatch(json!({"command":"protect","path":original,"passphrase":"synthetic passphrase","consent":true})).unwrap();
    let staged=manager.dispatch(json!({"command":"stage","vaultId":vault["vaultId"],"passphrase":"synthetic passphrase","consent":true})).unwrap();
    drop(manager);
    time.store(2000, Ordering::SeqCst);
    let manager = CredentialManager::with_clock(root.join("credentials"), clock).unwrap();
    assert!(!std::path::Path::new(staged["temporaryPath"].as_str().unwrap()).exists());
    let listed = manager.dispatch(json!({"command":"list"})).unwrap();
    assert_eq!(listed["vaults"].as_array().unwrap().len(), 1);
    assert!(listed["stages"].as_array().unwrap().is_empty());
    assert!(original.exists());
}

#[test]
fn ambiguous_csv_is_rejected_without_creating_a_vault_or_echoing_values() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().canonicalize().unwrap();
    let source = root.join("ambiguous.csv");
    fs::write(
        &source,
        "url,username,password,password\nhttps://example.test,user,do-not-echo,other\n",
    )
    .unwrap();
    let manager = CredentialManager::new(root.join("credentials")).unwrap();
    let error=manager.dispatch(json!({"command":"protect","path":source,"passphrase":"synthetic passphrase","consent":true})).unwrap_err();
    assert_eq!(error.code, "invalid_csv");
    assert!(!format!("{error:?}").contains("do-not-echo"));
    assert!(
        manager.dispatch(json!({"command":"list"})).unwrap()["vaults"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(source.exists());
}

#[test]
fn consent_is_required_before_reading_or_unlocking_any_source() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().canonicalize().unwrap();
    let manager = CredentialManager::new(root.join("credentials")).unwrap();
    for command in ["protect", "stage"] {
        let error=manager.dispatch(json!({"command":command,"path":"/does-not-exist","vaultId":"invalid","passphrase":"do-not-echo-secret","consent":false})).unwrap_err();
        assert_eq!(error.code, "consent_required");
        assert!(!format!("{error:?}").contains("do-not-echo-secret"));
    }
    assert!(
        manager.dispatch(json!({"command":"list"})).unwrap()["vaults"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[test]
fn sealed_storage_and_unlock_failures_reveal_no_password_values() {
    let home = tempfile::tempdir().unwrap();
    let root = home.path().canonicalize().unwrap();
    let source = root.join("original.csv");
    fs::write(
        &source,
        "url,username,password\nhttps://example.test,user,sensitive-canary-password\n",
    )
    .unwrap();
    let manager = CredentialManager::new(root.join("credentials")).unwrap();
    let vault=manager.dispatch(json!({"command":"protect","path":source,"passphrase":"correct synthetic passphrase","consent":true})).unwrap();
    let listed = manager.dispatch(json!({"command":"list"})).unwrap();
    assert!(!listed.to_string().contains("sensitive-canary-password"));
    let file = root
        .join("credentials/vaults")
        .join(format!("{}.json", vault["vaultId"].as_str().unwrap()));
    let bytes = fs::read(&file).unwrap();
    assert!(!String::from_utf8_lossy(&bytes).contains("sensitive-canary-password"));
    let wrong=manager.dispatch(json!({"command":"stage","vaultId":vault["vaultId"],"passphrase":"wrong synthetic passphrase","consent":true})).unwrap_err();
    assert_eq!(wrong.code, "unlock_failed");
    // A user-visible encrypted export is adversarial input too: authenticate its metadata.
    let mut envelope: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    envelope["count"] = json!(2);
    fs::write(&file, serde_json::to_vec(&envelope).unwrap()).unwrap();
    let changed=manager.dispatch(json!({"command":"stage","vaultId":vault["vaultId"],"passphrase":"correct synthetic passphrase","consent":true})).unwrap_err();
    assert_eq!(changed.code, "unlock_failed");
    assert!(!format!("{changed:?}").contains("sensitive-canary-password"));
    assert!(
        manager.dispatch(json!({"command":"list"})).unwrap()["stages"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[cfg(unix)]
#[test]
fn sensitive_files_are_owner_only_and_redirected_sources_are_rejected() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let home = tempfile::tempdir().unwrap();
    let root = home.path().canonicalize().unwrap();
    let source = root.join("original.csv");
    fs::write(
        &source,
        "url,username,password\nhttps://example.test,user,test-password\n",
    )
    .unwrap();
    let link = root.join("redirected.csv");
    symlink(&source, &link).unwrap();
    let manager = CredentialManager::new(root.join("credentials")).unwrap();
    let error=manager.dispatch(json!({"command":"protect","path":link,"passphrase":"synthetic passphrase","consent":true})).unwrap_err();
    assert_eq!(error.code, "unsafe_path");
    let vault=manager.dispatch(json!({"command":"protect","path":source,"passphrase":"synthetic passphrase","consent":true})).unwrap();
    let staged=manager.dispatch(json!({"command":"stage","vaultId":vault["vaultId"],"passphrase":"synthetic passphrase","consent":true})).unwrap();
    assert_eq!(
        fs::metadata(root.join("credentials"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert_eq!(
        fs::metadata(staged["temporaryPath"].as_str().unwrap())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    manager
        .dispatch(json!({"command":"cleanup","stageId":staged["stageId"]}))
        .unwrap();
    assert!(source.exists());
}
