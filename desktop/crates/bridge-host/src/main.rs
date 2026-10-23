use bridge_engine::{default_root, observe_caller, Engine, FRAME_LIMIT};
use serde_json::{json, Value};
use std::{
    io::{self, Read, Write},
    path::PathBuf,
};
fn main() {
    if let Err(error) = run() {
        eprintln!("Browser Bridge: {error}");
        std::process::exit(1)
    }
}
fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let resources = std::env::var_os("BROWSER_BRIDGE_RESOURCES")
        .map(PathBuf::from)
        .unwrap_or(
            std::env::current_exe()?
                .parent()
                .ok_or("Missing executable directory")?
                .to_path_buf(),
        );
    let engine = Engine::new(default_root(), resources)?;
    if args.first().map(String::as_str) == Some("--validate") {
        if args.len() != 3 {
            return Err("Usage: bridge-host --validate DISPOSABLE_ROOT REQUEST.json".into());
        }
        let request: Value = serde_json::from_slice(&std::fs::read(&args[2])?)?;
        let result = engine.validate_transfer(request, &PathBuf::from(&args[1]))?;
        println!("{}", serde_json::to_string_pretty(&result)?);
        return Ok(());
    }
    let origin = args
        .iter()
        .find(|v| {
            v.starts_with("chrome-extension://") || v.as_str() == bridge_engine::FIREFOX_ORIGIN
        })
        .ok_or("Missing allowed extension origin")?;
    let caller = observe_caller(origin)?;
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    loop {
        let mut header = [0; 4];
        match input.read_exact(&mut header) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => break,
            Err(error) => return Err(error.into()),
        }
        let length = u32::from_le_bytes(header) as usize;
        if length == 0 || length > FRAME_LIMIT {
            return Err("Native frame exceeds safety bound".into());
        }
        let mut payload = vec![0; length];
        input.read_exact(&mut payload)?;
        let result = match serde_json::from_slice::<Value>(&payload) {
            Ok(request) => engine
                .native_dispatch(&caller, request)
                .unwrap_or_else(|e| json!({"ok":false,"error":e.to_string()})),
            Err(_) => json!({"ok":false,"error":"Invalid native JSON"}),
        };
        let response = serde_json::to_vec(&result)?;
        if response.len() > bridge_engine::COMMAND_LIMIT {
            return Err("Native response exceeds safe browser frame size".into());
        }
        output.write_all(&(response.len() as u32).to_le_bytes())?;
        output.write_all(&response)?;
        output.flush()?;
    }
    Ok(())
}
