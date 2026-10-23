//! One bounded sensitive request over stdin. No credential values in argv, stderr or ordinary queues.
use bridge_sensitive::CredentialManager;
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    path::PathBuf,
};
use zeroize::Zeroizing;
const INPUT_LIMIT: u64 = 64 * 1024;
fn run() -> Value {
    let mut args = std::env::args_os().skip(1);
    if args.next().as_deref() != Some(std::ffi::OsStr::new("--root")) {
        return failure(
            "invalid_request",
            "Open the packaged app to use its protected credential helper.",
        );
    }
    let root = match args.next() {
        Some(path) => PathBuf::from(path),
        None => {
            return failure(
                "invalid_request",
                "The credential storage location is missing.",
            )
        }
    };
    if args.next().is_some() {
        return failure(
            "invalid_request",
            "Credential helper accepts only its storage location as an argument.",
        );
    }
    let mut input = Zeroizing::new(Vec::new());
    if std::io::stdin()
        .take(INPUT_LIMIT + 1)
        .read_to_end(&mut input)
        .is_err()
        || input.len() as u64 > INPUT_LIMIT
    {
        return failure(
            "oversized",
            "Credential request exceeds the supported size.",
        );
    }
    let request: Value = match serde_json::from_slice(&input) {
        Ok(value) => value,
        Err(_) => return failure("invalid_request", "The credential request is malformed."),
    };
    match CredentialManager::new(root).and_then(|manager| manager.dispatch(request)) {
        Ok(result) => json!({"ok":true,"result":result}),
        Err(error) => failure(error.code, error.message),
    }
}
fn failure(code: &str, message: &str) -> Value {
    json!({"ok":false,"error":{"code":code,"message":message}})
}
fn main() {
    let reply = run();
    let bytes = serde_json::to_vec(&reply).unwrap_or_default();
    let bytes = if bytes.len() > 1024 * 1024 {
        serde_json::to_vec(&failure(
            "oversized",
            "The credential result exceeds the supported size.",
        ))
        .unwrap_or_default()
    } else {
        bytes
    };
    let _ = std::io::stdout().write_all(&bytes);
}
