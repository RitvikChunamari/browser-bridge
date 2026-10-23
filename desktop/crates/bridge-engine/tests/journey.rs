use bridge_engine::{Caller, Engine};
use serde_json::json;
#[test]
fn pairing_authentication_and_guided_export_preserve_originals() {
    let raw = tempfile::tempdir().unwrap();
    let canonical = raw.path().canonicalize().unwrap();
    let temp = canonical.as_path();
    let profiles = temp.join("profiles");
    std::fs::create_dir_all(&profiles).unwrap();
    let source = profiles.join("Default");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::write(source.join("Preferences"), "original").unwrap();
    let importer = temp.join("resources/Importer");
    std::fs::create_dir_all(&importer).unwrap();
    let original = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .unwrap()
        .join("Resources/Importer");
    for file in std::fs::read_dir(original).unwrap() {
        let file = file.unwrap();
        if file.path().is_file() {
            std::fs::copy(file.path(), importer.join(file.file_name())).unwrap();
        }
    }
    let engine = Engine::new(temp.join("state"), temp.join("resources")).unwrap();
    let pair = engine
        .dispatch(json!({"command":"pair","browser":"chrome","profilePath":source}))
        .unwrap();
    let caller = Caller {
        browser: "chrome".into(),
        executable: "/fixture/chrome".into(),
        version: "fixture".into(),
        origin: bridge_engine::CHROMIUM_ORIGIN.into(),
    };
    let auth=engine.native_dispatch(&caller,json!({"action":"pair","code":pair["code"],"profileID":"bed5666b-11da-4ea7-890e-f08798eaa320","label":"Synthetic"})).unwrap();
    assert!(engine.native_dispatch(&caller,json!({"action":"poll","connectionID":auth["connectionID"],"secret":"wrong","profileID":"bed5666b-11da-4ea7-890e-f08798eaa320"})).is_err());
    let state = engine.dispatch(json!({"command":"status"})).unwrap();
    assert!(!state.to_string().contains(auth["secret"].as_str().unwrap()));
    assert_eq!(state["connections"][0]["readiness"], "guided");
    let capture = json!({"schema":1,"format":"browser-bridge-capture","browser":"chrome","capturedAt":"fixture","snapshot":{"spaces":[],"folders":[],"tabs":[{"id":"1","url":"https://example.test/","title":"Example","pinned":true}],"bookmarks":[{"id":1,"parent":0,"type":2,"title":"Preserved folder"},{"id":2,"parent":1,"type":1,"title":"Saved","url":"https://saved.test/"}],"history":[]}});
    let job = engine
        .enqueue_validation(
            auth["connectionID"].as_str().unwrap(),
            "capture",
            json!({"history":false,"guidedExport":true}),
            temp,
        )
        .unwrap();
    let poll=engine.native_dispatch(&caller,json!({"action":"poll","connectionID":auth["connectionID"],"secret":auth["secret"],"profileID":"bed5666b-11da-4ea7-890e-f08798eaa320"})).unwrap();
    assert_eq!(poll["job"]["id"], job);
    engine.native_dispatch(&caller,json!({"action":"complete","connectionID":auth["connectionID"],"secret":auth["secret"],"profileID":"bed5666b-11da-4ea7-890e-f08798eaa320","jobID":job,"result":{"ok":true,"capture":capture}})).unwrap();
    let out=engine.dispatch(json!({"command":"buildGuidedPackage","sourceId":auth["connectionID"],"backupDirectory":temp.join("packages")})).unwrap();
    let path = std::path::PathBuf::from(out["packagePath"].as_str().unwrap());
    assert!(path.join("Bookmarks.html").is_file());
    assert!(std::fs::read_to_string(path.join("Bookmarks.html"))
        .unwrap()
        .contains("https://example.test/"));
    assert!(std::fs::read_to_string(path.join("Bookmarks.html"))
        .unwrap()
        .contains("<H3>Preserved folder</H3>"));
    assert!(path.join("backup-manifest.json").is_file());
    assert!(path.join("Importer/manifest.json").is_file());
    let packaged: serde_json::Value =
        serde_json::from_slice(&std::fs::read(path.join("Importer/data.json")).unwrap()).unwrap();
    assert_eq!(packaged["snapshot"]["tabs"][0]["pinned"], true);
    assert_eq!(
        packaged["snapshot"]["bookmarks"][0]["title"],
        "Preserved folder"
    );
    // A completed capture from another operation is not the next export, especially after option changes.
    let unrelated = engine
        .enqueue_validation(
            auth["connectionID"].as_str().unwrap(),
            "capture",
            json!({"history":false}),
            temp,
        )
        .unwrap();
    let mut native = json!({"action":"poll","connectionID":auth["connectionID"],"secret":auth["secret"],"profileID":"bed5666b-11da-4ea7-890e-f08798eaa320"});
    engine.native_dispatch(&caller, native.clone()).unwrap();
    native["action"] = json!("complete");
    native["jobID"] = json!(unrelated);
    native["result"] = json!({"ok":true,"capture":capture});
    engine.native_dispatch(&caller, native).unwrap();
    let browser = engine.clone();
    let browser_caller = caller.clone();
    let browser_auth = auth.clone();
    let mut latest = capture.clone();
    latest["snapshot"]["tabs"][0]["url"] = json!("https://fresh-export.test/");
    let refresh = std::thread::spawn(move || {
        for _ in 0..300 {
            let mut request = json!({"action":"poll","connectionID":browser_auth["connectionID"],"secret":browser_auth["secret"],"profileID":"bed5666b-11da-4ea7-890e-f08798eaa320"});
            let poll = browser
                .native_dispatch(&browser_caller, request.clone())
                .unwrap();
            if let Some(job) = poll.get("job") {
                assert_eq!(job["payload"]["history"], true);
                assert_eq!(job["payload"]["guidedExport"], true);
                request["action"] = json!("complete");
                request["jobID"] = job["id"].clone();
                request["result"] = json!({"ok":true,"capture":latest});
                browser.native_dispatch(&browser_caller, request).unwrap();
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        panic!("New guided capture was never requested")
    });
    let second=engine.dispatch(json!({"command":"buildGuidedPackage","sourceId":auth["connectionID"],"backupDirectory":temp.join("packages"),"options":{"history":true}})).unwrap();
    refresh.join().unwrap();
    let fresh = std::fs::read_to_string(
        std::path::Path::new(second["packagePath"].as_str().unwrap()).join("Bookmarks.html"),
    )
    .unwrap();
    assert!(fresh.contains("https://fresh-export.test/"));
    assert!(!fresh.contains("https://example.test/"));
    assert_eq!(
        std::fs::read_to_string(source.join("Preferences")).unwrap(),
        "original"
    );
}

#[test]
fn complete_disposable_journey_verifies_baseline_and_rolls_back_owned_changes() {
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    };
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let engine = Engine::new(root.join("state"), root.join("resources")).unwrap();
    let executable = root.join(if cfg!(windows) {
        "fixture-browser.exe"
    } else {
        "fixture-browser"
    });
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::write(&executable, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    // A copied test harness rejects the browser flags and exits without running tests.
    #[cfg(windows)]
    std::fs::copy(std::env::current_exe().unwrap(), &executable).unwrap();
    let caller = Caller {
        browser: "chrome".into(),
        executable,
        version: "fixture".into(),
        origin: bridge_engine::CHROMIUM_ORIGIN.into(),
    };
    let mut auths = vec![];
    for name in ["Source", "Destination"] {
        let path = root.join(name);
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("Preferences"), name).unwrap();
        let pair = engine
            .dispatch(json!({"command":"pair","browser":"chrome","profilePath":path}))
            .unwrap();
        let profile = uuid::Uuid::new_v4().to_string();
        let auth = engine
            .native_dispatch(
                &caller,
                json!({"action":"pair","code":pair["code"],"profileID":profile,"label":name}),
            )
            .unwrap();
        auths.push((auth, profile));
    }
    let destination = auths[1].0["connectionID"].clone();
    let source = auths[0].0["connectionID"].clone();
    assert!(engine.dispatch(json!({"command":"transfer","sourceId":source,"destinationId":destination,"backupDirectory":root.join("packages")})).is_err());
    let stopped = Arc::new(AtomicBool::new(false));
    let stop = stopped.clone();
    let fixture_engine = engine.clone();
    let worker = std::thread::spawn(move || {
        use std::io::{BufRead, Write};
        let repository = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .nth(3)
            .unwrap();
        let mut fixtures: Vec<_> = ["source", "destination"]
            .iter()
            .map(|role| {
                let mut child = std::process::Command::new("node")
                    .arg(
                        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                            .join("tests/browser-fixture.mjs"),
                    )
                    .arg(repository)
                    .arg(role)
                    .stdin(std::process::Stdio::piped())
                    .stdout(std::process::Stdio::piped())
                    .spawn()
                    .expect("Node.js is required for the existing connector contract journey");
                let input = child.stdin.take().unwrap();
                let output = std::io::BufReader::new(child.stdout.take().unwrap());
                (child, input, output)
            })
            .collect();
        let mut interrupt_import = true;
        while !stop.load(Ordering::SeqCst) {
            for (index, (auth, profile)) in auths.iter().enumerate() {
                let mut req = json!({"action":"poll","connectionID":auth["connectionID"],"secret":auth["secret"],"profileID":profile,"capabilities":["tabs","bookmarks","groups"]});
                let poll = fixture_engine
                    .native_dispatch(&caller, req.clone())
                    .unwrap();
                if let Some(job) = poll.get("job") {
                    let (_, input, output) = &mut fixtures[index];
                    writeln!(
                        input,
                        "{}",
                        json!({"operation":job["operation"],"payload":job["payload"]})
                    )
                    .unwrap();
                    input.flush().unwrap();
                    let mut line = String::new();
                    output.read_line(&mut line).unwrap();
                    let mut result: serde_json::Value = serde_json::from_str(&line).unwrap();
                    if job["operation"] == "import" && interrupt_import {
                        interrupt_import = false;
                        result = json!({"ok":false,"error":"Injected interruption after helper checkpoint"});
                    }
                    req["action"] = json!("complete");
                    req["jobID"] = job["id"].clone();
                    req["result"] = result;
                    fixture_engine.native_dispatch(&caller, req).unwrap();
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        for (mut child, input, _) in fixtures {
            drop(input);
            assert!(child.wait().unwrap().success());
        }
    });
    assert!(engine.validate_transfer(json!({"sourceId":source,"destinationId":destination,"backupDirectory":root.join("packages")}),&root).is_err());
    let paused = engine.dispatch(json!({"command":"status"})).unwrap()["receipts"][0].clone();
    assert_eq!(paused["phase"], "importing");
    let receipt = engine
        .validate_transfer(json!({"receiptId":paused["id"]}), &root)
        .unwrap();
    assert_eq!(receipt["phase"], "complete");
    assert_eq!(receipt["baselinePreserved"], true);
    assert_eq!(receipt["verification"]["expectedCounts"]["tabs"], 1);
    assert_eq!(receipt["verification"]["expectedCounts"]["bookmarks"], 2);
    assert!(!receipt.to_string().contains("https://"));
    let again = engine
        .validate_transfer(json!({"receiptId":receipt["id"]}), &root)
        .unwrap();
    assert_eq!(again["id"], receipt["id"]);
    assert!(engine
        .dispatch(json!({"command":"rollback","receiptId":receipt["id"]}))
        .is_err());
    let rollback=engine.dispatch(json!({"command":"rollback","receiptId":receipt["id"],"confirmedOwnedChangesRemoval":true})).unwrap();
    assert_eq!(rollback["phase"], "rolledBack");
    assert_eq!(
        std::fs::read_to_string(root.join("Source/Preferences")).unwrap(),
        "Source"
    );
    assert_eq!(
        std::fs::read_to_string(root.join("Destination/Preferences")).unwrap(),
        "Destination"
    );
    stopped.store(true, Ordering::SeqCst);
    worker.join().unwrap();
}

#[cfg(unix)]
#[test]
fn rejected_paths_origins_and_oversized_jobs_cannot_change_profile_data() {
    let raw = tempfile::tempdir().unwrap();
    let root = raw.path().canonicalize().unwrap();
    let profile = root.join("profile");
    std::fs::create_dir(&profile).unwrap();
    std::fs::write(profile.join("Preferences"), "unchanged").unwrap();
    let alias = root.join("alias");
    std::os::unix::fs::symlink(&profile, &alias).unwrap();
    let engine = Engine::new(root.join("state"), root.join("resources")).unwrap();
    assert!(engine
        .dispatch(json!({"command":"pair","browser":"chrome","profilePath":alias}))
        .is_err());
    let pair = engine
        .dispatch(json!({"command":"pair","browser":"chrome","profilePath":profile}))
        .unwrap();
    let mut caller = Caller {
        browser: "chrome".into(),
        executable: root.join("fixture"),
        version: "fixture".into(),
        origin: "chrome-extension://untrusted/".into(),
    };
    let profile_id = uuid::Uuid::new_v4().to_string();
    let request = json!({"action":"pair","code":pair["code"],"profileID":profile_id});
    assert!(engine.native_dispatch(&caller, request.clone()).is_err());
    caller.origin = bridge_engine::CHROMIUM_ORIGIN.into();
    let auth = engine.native_dispatch(&caller, request).unwrap();
    assert!(engine
        .enqueue_validation(
            auth["connectionID"].as_str().unwrap(),
            "import",
            json!({"oversized":"x".repeat(710_000)}),
            &root
        )
        .is_err());
    assert!(engine
        .enqueue_validation(
            auth["connectionID"].as_str().unwrap(),
            "capture",
            json!({}),
            &root.join("state")
        )
        .is_err());
    assert!(engine.native_dispatch(&caller,json!({"action":"transfer","connectionID":auth["connectionID"],"secret":auth["secret"],"profileID":profile_id,"path":"/tmp/escape"})).is_err());
    assert_eq!(
        std::fs::read_to_string(profile.join("Preferences")).unwrap(),
        "unchanged"
    );
}
