use bridge_engine::Engine;
use serde_json::json;
#[test]
fn sensitive_routes_require_consent_and_platform_acceptance() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let engine = Engine::new(root.join("state"), root.join("resources")).unwrap();
    assert!(engine.dispatch(json!({"command":"sessions.start","sourceId":"source","destinationId":"destination","origins":["https://example.test"],"consent":false})).is_err());
    let plan = engine
        .dispatch(json!({"command":"sessions.plan","origins":["https://example.test"]}))
        .unwrap();
    assert_eq!(plan["eligible"], false);
    assert!(engine
        .dispatch(json!({"command":"sessions.plan","origins":["https://example.test/path"]}))
        .is_err());
    assert!(engine.validate_session(json!({"sourceId":"source","destinationId":"destination","origins":["https://example.test"],"consent":false}),&root).is_err());
}

#[test]
fn webcrypto_rust_transport_is_sealed_and_cookie_copy_is_not_login_proof() {
    use bridge_engine::{Caller, CHROMIUM_ORIGIN};
    use std::{
        io::{BufRead, Read, Write},
        sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        },
    };
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let engine = Engine::new(root.join("state"), root.join("resources")).unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let stop = Arc::new(AtomicBool::new(false));
    let service_flag = Arc::new(AtomicBool::new(false));
    let service_stop = service_flag.clone();
    let service = std::thread::spawn(move || {
        while !service_stop.load(Ordering::SeqCst) {
            if let Ok((mut socket, _)) = listener.accept() {
                socket.set_nonblocking(false).unwrap();
                socket
                    .set_read_timeout(Some(std::time::Duration::from_secs(2)))
                    .unwrap();
                let mut input = [0u8; 8192];
                let n = socket.read(&mut input).unwrap();
                let authenticated =
                    String::from_utf8_lossy(&input[..n]).contains("session=fixture-session-secret");
                let body = format!("{{\"authenticated\":{authenticated}}}");
                write!(socket,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",body.len(),body).unwrap();
            } else {
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        }
    });
    let caller = Caller {
        browser: "chrome".into(),
        executable: root.join("fixture-browser"),
        version: "fixture".into(),
        origin: CHROMIUM_ORIGIN.into(),
    };
    let mut auths = vec![];
    for role in ["source", "destination"] {
        let path = root.join(role);
        std::fs::create_dir(&path).unwrap();
        let pair = engine
            .dispatch(json!({"command":"pair","browser":"chrome","profilePath":path}))
            .unwrap();
        let profile = uuid::Uuid::new_v4().to_string();
        let auth = engine
            .native_dispatch(
                &caller,
                json!({"action":"pair","code":pair["code"],"profileID":profile}),
            )
            .unwrap();
        auths.push((auth, profile));
    }
    let source = auths[0].0["connectionID"].clone();
    let destination = auths[1].0["connectionID"].clone();
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
                        .join("tests/session-fixture.mjs"),
                )
                .arg(repository)
                .arg(role)
                .arg(&origin)
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .spawn()
                .unwrap();
            let stdin = child.stdin.take().unwrap();
            let stdout = std::io::BufReader::new(child.stdout.take().unwrap());
            (child, stdin, stdout)
        })
        .collect();
    fn ask(
        fixture: &mut (
            std::process::Child,
            std::process::ChildStdin,
            std::io::BufReader<std::process::ChildStdout>,
        ),
        request: serde_json::Value,
    ) -> serde_json::Value {
        writeln!(fixture.1, "{request}").unwrap();
        fixture.1.flush().unwrap();
        let mut line = String::new();
        fixture.2.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap()
    }
    let before = ask(
        &mut fixtures[1],
        json!({"operation":"fixture.auth","payload":{}}),
    );
    assert_eq!(before["httpStatus"], 200);
    assert_eq!(before["authenticated"], false);
    let fixture_engine = engine.clone();
    let worker_stop = stop.clone();
    let worker = std::thread::spawn(move || {
        while !worker_stop.load(Ordering::SeqCst) {
            for (index, (auth, profile)) in auths.iter().enumerate() {
                let mut request = json!({"action":"poll","connectionID":auth["connectionID"],"secret":auth["secret"],"profileID":profile});
                let poll = fixture_engine
                    .native_dispatch(&caller, request.clone())
                    .unwrap();
                if let Some(job) = poll.get("job") {
                    let result = ask(
                        &mut fixtures[index],
                        json!({"operation":job["operation"],"payload":job["payload"]}),
                    );
                    request["action"] = json!("complete");
                    request["jobID"] = job["id"].clone();
                    request["result"] = result;
                    fixture_engine.native_dispatch(&caller, request).unwrap();
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let after = ask(
            &mut fixtures[1],
            json!({"operation":"fixture.auth","payload":{}}),
        );
        for (mut child, input, _) in fixtures {
            drop(input);
            child.wait().unwrap();
        }
        after
    });
    let result=engine.validate_session(json!({"sourceId":source,"destinationId":destination,"origins":[origin],"consent":true}),&root).unwrap();
    assert_eq!(result["phase"], "cookiesVerified");
    assert_eq!(result["cookies"]["verified"], 1);
    assert_eq!(result["sessionOutcome"], "unverified");
    let state = std::fs::read_to_string(root.join("state/state.json")).unwrap();
    assert!(!state.contains("fixture-session-secret"));
    assert!(!state.contains("privateKey"));
    assert!(!result.to_string().contains("ciphertext"));
    let confirmed=engine.dispatch(json!({"command":"sessions.confirm","sessionId":result["id"],"confirmedSignedIn":false})).unwrap();
    assert_eq!(confirmed["sessionOutcome"], "reloginRequired");
    let cleaned = engine
        .dispatch(json!({"command":"sessions.cleanup","sessionId":result["id"]}))
        .unwrap();
    assert_eq!(cleaned["sealedTransportCleaned"], true);
    stop.store(true, Ordering::SeqCst);
    let after = worker.join().unwrap();
    assert_eq!(after["httpStatus"], 200);
    assert_eq!(after["authenticated"], true);
    service_flag.store(true, Ordering::SeqCst);
    service.join().unwrap();
}

#[test]
fn sensitive_native_results_reject_plaintext_and_redact_browser_errors_before_persistence() {
    use bridge_engine::{Caller, CHROMIUM_ORIGIN};
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let profile = root.join("profile");
    std::fs::create_dir(&profile).unwrap();
    let engine = Engine::new(root.join("state"), root.join("resources")).unwrap();
    let pair = engine
        .dispatch(json!({"command":"pair","browser":"chrome","profilePath":profile}))
        .unwrap();
    let profile_id = uuid::Uuid::new_v4().to_string();
    let caller = Caller {
        browser: "chrome".into(),
        executable: root.join("fixture"),
        version: "fixture".into(),
        origin: CHROMIUM_ORIGIN.into(),
    };
    let auth = engine
        .native_dispatch(
            &caller,
            json!({"action":"pair","code":pair["code"],"profileID":profile_id}),
        )
        .unwrap();
    let job = engine
        .enqueue_validation(
            auth["connectionID"].as_str().unwrap(),
            "cookies.capture",
            json!({"sessionId":"fixture","origins":["https://example.test"]}),
            &root,
        )
        .unwrap();
    let mut request = json!({"action":"poll","connectionID":auth["connectionID"],"secret":auth["secret"],"profileID":profile_id});
    engine.native_dispatch(&caller, request.clone()).unwrap();
    request["action"] = json!("complete");
    request["jobID"] = json!(job);
    request["result"] = json!({"ok":true,"cookies":[{"value":"never-persist-cookie-value"}]});
    assert!(engine.native_dispatch(&caller, request.clone()).is_err());
    request["result"] =
        json!({"ok":false,"error":"Browser accidentally included never-persist-cookie-value"});
    engine.native_dispatch(&caller, request).unwrap();
    assert!(!std::fs::read_to_string(root.join("state/state.json"))
        .unwrap()
        .contains("never-persist-cookie-value"));
}

#[test]
fn cleanup_cannot_unlock_an_in_flight_sensitive_operation() {
    use bridge_engine::{Caller, CHROMIUM_ORIGIN};
    let raw = tempfile::tempdir().unwrap();
    let root = raw.path().canonicalize().unwrap();
    let engine = Engine::new(root.join("state"), root.join("resources")).unwrap();
    let caller = Caller {
        browser: "chrome".into(),
        executable: root.join("fixture"),
        version: "fixture".into(),
        origin: CHROMIUM_ORIGIN.into(),
    };
    let mut connected = vec![];
    for role in ["source", "destination"] {
        let path = root.join(role);
        std::fs::create_dir(&path).unwrap();
        let pair = engine
            .dispatch(json!({"command":"pair","browser":"chrome","profilePath":path}))
            .unwrap();
        let profile = uuid::Uuid::new_v4().to_string();
        let auth = engine
            .native_dispatch(
                &caller,
                json!({"action":"pair","code":pair["code"],"profileID":profile}),
            )
            .unwrap();
        connected.push((auth, profile));
    }
    let source = connected[0].0["connectionID"].clone();
    let destination = connected[1].0["connectionID"].clone();
    let worker = engine.clone();
    let disposable = root.clone();
    let run = std::thread::spawn(move || {
        worker.validate_session(json!({"sourceId":source,"destinationId":destination,"origins":["https://example.test"],"consent":true}),&disposable)
    });
    let (auth, profile) = &connected[1];
    let mut request = json!({"action":"poll","connectionID":auth["connectionID"],"secret":auth["secret"],"profileID":profile});
    let mut job = None;
    for _ in 0..200 {
        let poll = engine.native_dispatch(&caller, request.clone()).unwrap();
        if poll.get("job").is_some() {
            job = Some(poll["job"].clone());
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let job = job.expect("Coordinator requested destination preparation");
    let status = engine
        .dispatch(json!({"command":"sessions.status"}))
        .unwrap();
    let session = status["sessions"][0]["id"].clone();
    assert!(engine
        .dispatch(json!({"command":"sessions.cleanup","sessionId":session}))
        .is_err());
    assert_eq!(
        engine.native_dispatch(&caller, request.clone()).unwrap()["job"]["id"],
        job["id"]
    );
    request["action"] = json!("complete");
    request["jobID"] = job["id"].clone();
    request["result"] = json!({"ok":false,"error":"User declined permission"});
    engine.native_dispatch(&caller, request).unwrap();
    assert!(run.join().unwrap().is_err());
    let status = engine
        .dispatch(json!({"command":"sessions.status","sessionId":session}))
        .unwrap();
    assert_eq!(status["sessions"][0]["phase"], "restagingRequired");
}
