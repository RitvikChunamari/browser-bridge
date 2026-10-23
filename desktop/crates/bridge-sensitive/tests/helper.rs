use serde_json::{json, Value};
use std::{
    io::Write,
    process::{Command, Stdio},
};

fn request(root: &std::path::Path, input: &[u8]) -> (Value, Vec<u8>) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_bridge-credentials"))
        .arg("--root")
        .arg(root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    let output = child.wait_with_output().unwrap();
    (
        serde_json::from_slice(&output.stdout).unwrap(),
        output.stderr,
    )
}
#[test]
fn bounded_cli_protects_synthetic_export_and_returns_only_redacted_metadata() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().canonicalize().unwrap();
    let source = home.join("source.csv");
    std::fs::write(
        &source,
        "url,username,password\nhttps://example.test,user,synthetic-password\n",
    )
    .unwrap();
    let (protected,stderr)=request(&home.join("credentials"),&serde_json::to_vec(&json!({"command":"protect","path":source,"passphrase":"synthetic helper passphrase","consent":true})).unwrap());
    assert_eq!(protected["ok"], true);
    assert_eq!(protected["result"]["count"], 1);
    assert!(!protected.to_string().contains("synthetic-password"));
    assert!(stderr.is_empty());
    let (listed, _) = request(&home.join("credentials"), br#"{"command":"list"}"#);
    assert_eq!(listed["result"]["vaults"].as_array().unwrap().len(), 1);
    let (staged, _) = request(&home.join("credentials"), &serde_json::to_vec(&json!({"command":"stage","vaultId":protected["result"]["vaultId"],"passphrase":"synthetic helper passphrase","consent":true})).unwrap());
    assert_eq!(staged["ok"], true);
    let path = std::path::PathBuf::from(staged["result"]["temporaryPath"].as_str().unwrap());
    assert!(std::fs::read_to_string(&path)
        .unwrap()
        .contains("synthetic-password"));
    let (confirmed, _) = request(&home.join("credentials"), &serde_json::to_vec(&json!({"command":"confirmImport","stageId":staged["result"]["stageId"],"confirmed":true})).unwrap());
    assert_eq!(confirmed["result"]["verified"], false);
    assert!(!path.exists());
    assert!(source.exists());
    let (oversized, stderr) = request(&home.join("credentials"), &vec![b'x'; 65_537]);
    assert_eq!(oversized["error"]["code"], "oversized");
    assert!(stderr.is_empty());
    let (invalid, stderr) = request(&home.join("credentials"), b"not JSON synthetic-password");
    assert_eq!(invalid["ok"], false);
    assert!(!invalid.to_string().contains("synthetic-password"));
    assert!(stderr.is_empty());
}
