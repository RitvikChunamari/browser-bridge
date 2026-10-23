use super::*;
use sha2::{Digest, Sha256};
use std::time::Duration;
pub(crate) fn redact_receipt(receipt: &Value) -> Value {
    let mut out = receipt.clone();
    if let Some(map) = out.as_object_mut() {
        for key in [
            "sourceCapture",
            "destinationCapture",
            "intent",
            "activePayload",
            "baseline",
        ] {
            map.remove(key);
        }
    }
    out
}
impl Engine {
    pub(crate) fn plan(&self, v: &Value) -> Result<Value> {
        self.transaction(|s|{let source=s.connections.iter().find(|c|Some(c.id.as_str())==v["sourceId"].as_str()).ok_or_else(||EngineError("Select a connected source".into()))?;let dest=s.connections.iter().find(|c|Some(c.id.as_str())==v["destinationId"].as_str());Ok(json!({"readiness":"guided","automatic":false,"source":source.browser,"destination":dest.map(|c|&c.browser),"categories":[{"category":"bookmarks","outcome":"HTML import"},{"category":"tabs","outcome":"Saved links, pins and groups retained in capture"},{"category":"history","outcome":"Capture only when browser permission granted"},{"category":"spaces/folders/essentials","outcome":"Original metadata retained; exact destination behavior depends on its APIs"}],"blockers":["No automatic Windows/Linux pair has completed real platform acceptance. Build a guided package or use the explicitly disposable validation CLI."]}))})
    }
    fn connection(&self, id: &str) -> Result<Connection> {
        self.transaction(|s| {
            s.connections
                .iter()
                .find(|c| c.id == id)
                .cloned()
                .ok_or_else(|| {
                    EngineError(
                        "Original paired profile is unavailable; reconnect it before continuing"
                            .into(),
                    )
                })
        })
    }
    pub(crate) fn guided(&self, v: &Value) -> Result<Value> {
        let source = self.connection(field(v, "sourceId")?)?;
        let destination = if let Some(id) = v["destinationId"].as_str() {
            Some(self.connection(id)?)
        } else {
            None
        };
        let base = checked_backup_base(
            Path::new(field(v, "backupDirectory")?),
            &source.path,
            destination.as_ref().map(|c| c.path.as_path()),
        )?;

        let capture = self.transaction(|s| {
            Ok(s.jobs
                .iter()
                .rev()
                .find(|j| {
                    j.connection == source.id
                        && j.operation == "capture"
                        && !j.export_used
                        && j.payload["guidedExport"] == true
                        && (j.payload["history"] == true) == (v["options"]["history"] == true)
                        && now().saturating_sub(j.created_at) < 60
                        && j.result.as_ref().is_some_and(|r| r["ok"] == true)
                })
                .and_then(|j| {
                    j.result
                        .as_ref()
                        .and_then(|r| r.get("capture"))
                        .map(|capture| (j.id.clone(), capture.clone()))
                }))
        })?;
        let (capture_job, capture) = match capture {
            Some(c) => c,
            None => {
                let job = self.enqueue(
                    &source.id,
                    "capture",
                    json!({"history":v["options"]["history"]==true,"guidedExport":true}),
                )?;
                let capture = self
                    .wait_job(&job)?
                    .get("capture")
                    .cloned()
                    .ok_or_else(|| EngineError("Capture result missing".into()))?;
                (job, capture)
            }
        };
        validate_capture(&capture)?;
        if base.exists() {
            validate_tree(&base)?;
        } else {
            private_directory(&base)?;
        }
        let path = base.join(format!("Browser-Bridge-{}", id()));
        let archive = self.root.join("CaptureArchive");
        private_directory(&archive)?;
        atomic_json(&archive.join(format!("{capture_job}.json")), &capture)?;
        let capture = selected_capture(capture, &v["options"]);
        private_directory(&path)?;
        atomic_json(&path.join("capture.json"), &capture)?;
        atomic_bytes(&path.join("Bookmarks.html"), html(&capture).as_bytes())?;
        atomic_bytes(&path.join("README.txt"),b"Import Bookmarks.html using your destination browser's bookmark import menu. Capture.json preserves tabs, pins, groups and other portable metadata. Browser-specific spaces and credentials need separate guided setup. Source profile was not modified. This is an export package, not a full live-profile backup.\n")?;
        let importer = self.resources.join("Importer");
        if importer.is_dir() {
            copy_profile(&importer, &path.join("Importer"))?;
            atomic_json(
                &path.join("Importer/data.json"),
                &json!({"schema":1,"packageID":id(),"createdAt":now().to_string(),"sourceBrowser":source.browser,"targetBrowser":v["destinationId"].as_str().and_then(|id|self.connection(id).ok()).map(|c|c.browser),"snapshot":capture["snapshot"]}),
            )?;
            atomic_bytes(&path.join("README.txt"),b"BOOKMARKS: Import Bookmarks.html through the destination browser's bookmark-import menu.
TABS / PINS / GROUP APPROXIMATIONS / OPTIONAL HISTORY: Chromium browsers: open Extensions, enable Developer mode, and Load unpacked the Importer folder. Click its toolbar icon, review the inventory, and choose categories. Firefox: use its add-on debugging page and the supplied manifest-firefox.json renamed manifest.json in a private copy; temporary add-ons disappear on restart. Exact native spaces/Essentials, credentials and sessions require separate setup.
The helper creates its own bookmark tree and journal. Rollback removes that owned tree including edits inside it; history and uncertain or changed tabs are retained. Export capture.json preserves additional metadata. This package is a portable export, not a full live-profile backup. Keep it private.
")?;
        }
        write_manifest(&path)?;
        self.transaction(|s| {
            if let Some(job) = s.jobs.iter_mut().find(|j| j.id == capture_job) {
                job.export_used = true;
            }
            Ok(())
        })?;
        Ok(
            json!({"packagePath":path,"readiness":"guided","message":"Import Bookmarks.html in the destination browser. The original capture retains additional metadata."}),
        )
    }
    pub(crate) fn recover(&self, v: &Value) -> Result<Value> {
        let rid = field(v, "receiptId")?;
        let receipt = self.transaction(|s| {
            s.receipts
                .iter()
                .find(|r| r["id"] == rid)
                .cloned()
                .ok_or_else(|| EngineError("Unknown receipt".into()))
        })?;
        match field(v,"command")?{"cancel"=>self.transaction(|s|{let current=s.receipts.iter().find(|r|r["id"]==rid).ok_or_else(||EngineError("Receipt missing".into()))?;let active=current["activeJob"].as_str().ok_or_else(||EngineError("No unclaimed operation to cancel".into()))?;let job=s.jobs.iter().find(|j|j.id==active).ok_or_else(||EngineError("Active job missing; keep the receipt recoverable".into()))?;if job.claimed||job.result.is_some(){return fail("Operation may have executed; Resume or Rollback instead")};s.jobs.retain(|j|j.id!=active);let r=s.receipts.iter_mut().find(|r|r["id"]==rid).unwrap();r["activeJob"]=Value::Null;r["paused"]=json!(true);r["error"]=json!("Undelivered step cancelled. Existing effects remain recoverable through Resume or Rollback.");Ok(redact_receipt(r))}),"rollback"=>{if v["confirmedOwnedChangesRemoval"]!=true{return fail("Confirm removal of this transfer's owned bookmark tree, including edits inside it. History and uncertain/changed tabs are retained.")};let dest=self.connection(field(&receipt,"destinationId")?)?;let package=field(&receipt,"packagePath")?;verify_manifest(Path::new(package))?;let lease=open_private(&self.root.join("coordinator.lock"))?;lease.try_lock_exclusive().map_err(|_|EngineError("Another transfer is running".into()))?;
self.transaction(|s|{let active=s.receipts.iter().find(|r|r["id"]==rid).and_then(|r|r["activeJob"].as_str()).map(str::to_owned);if let Some(active)=active{let job=s.jobs.iter().find(|j|j.id==active).ok_or_else(||EngineError("Receipt job missing".into()))?;if job.operation!="rollback"{if job.result.is_none(){return fail("A prior operation is still pending. Resume it or cancel it before rollback")};s.receipts.iter_mut().find(|r|r["id"]==rid).unwrap()["activeJob"]=Value::Null;}}Ok(())})?;
self.save_receipt(rid,|r|{r["phase"]=json!("rollingBack");r["rollbackConsent"]=json!(true);})?;let result=self.step(rid,&dest.id,"rollback",json!({"packageID":receipt["packageID"]}))?;self.save_receipt(rid,|r|{r["phase"]=json!(if result["journal"]["state"]=="rolled-back"{"rolledBack"}else{"rollbackPartial"});r["warnings"]=json!(["History is retained. Changed, restarted or uncertain tabs are preserved."]);r["activeJob"]=Value::Null;})},_=>fail("Production automatic routes remain unverified. Resume using the explicit disposable validation CLI for validation receipts.")}
    }
    pub(crate) fn save_receipt(&self, id: &str, edit: impl FnOnce(&mut Value)) -> Result<Value> {
        self.transaction(|s| {
            let r = s
                .receipts
                .iter_mut()
                .find(|r| r["id"] == id)
                .ok_or_else(|| EngineError("Receipt missing".into()))?;
            edit(r);
            r["updatedAt"] = json!(now());
            Ok(redact_receipt(r))
        })
    }
    pub(crate) fn wait_job(&self, id: &str) -> Result<Value> {
        for _ in 0..120 {
            if let Some(result) = self.transaction(|s| {
                Ok(s.jobs
                    .iter()
                    .find(|j| j.id == id)
                    .and_then(|j| j.result.clone()))
            })? {
                if result["ok"] != true {
                    return fail(result["error"].as_str().unwrap_or(
                        "Connector operation failed; inspect browser setup and Resume",
                    ));
                }
                return Ok(result);
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        fail("Connector did not finish. Keep the correct profile and connector open, then Resume; the same queued operation will be reused.")
    }
    fn step(&self, rid: &str, connection: &str, operation: &str, payload: Value) -> Result<Value> {
        let existing = self.transaction(|s| {
            Ok(s.receipts
                .iter()
                .find(|r| r["id"] == rid)
                .and_then(|r| r["activeJob"].as_str())
                .map(String::from))
        })?;
        let job = if let Some(job) = existing {
            self.transaction(|s| {
                let j = s
                    .jobs
                    .iter()
                    .find(|j| j.id == job)
                    .ok_or_else(|| EngineError("Receipt job missing".into()))?;
                if j.connection != connection || j.operation != operation || j.payload != payload {
                    return fail("Receipt and queued operation differ; no new operation was sent");
                };
                Ok(job)
            })?
        } else {
            let job = self.enqueue(connection, operation, payload)?;
            self.save_receipt(rid, |r| r["activeJob"] = json!(job))?;
            job
        };
        let result = self.wait_job(&job)?;
        Ok(result)
    }
    /// Runs the real coordinator only inside a caller-selected disposable root. Not exposed to renderer requests.
    pub fn validate_transfer(&self, request: Value, disposable_root: &Path) -> Result<Value> {
        self.validate_disposable(disposable_root)?;
        if matches!(request["command"].as_str(), Some("rollback" | "cancel")) {
            return self.recover(&request);
        }
        let lease = open_private(&self.root.join("coordinator.lock"))?;
        lease
            .try_lock_exclusive()
            .map_err(|_| EngineError("Another transfer is running".into()))?;
        let rid = if let Some(id) = request["receiptId"].as_str() {
            id.to_string()
        } else {
            let source = self.connection(field(&request, "sourceId")?)?;
            let dest = self.connection(field(&request, "destinationId")?)?;
            if source.path == dest.path {
                return fail("Source and destination must be different profiles");
            };
            let directory = PathBuf::from(field(&request, "backupDirectory")?);
            let root = disposable_root.canonicalize()?;
            private_directory(&directory)?;
            let directory = directory.canonicalize()?;
            if directory.starts_with(&source.path) || directory.starts_with(&dest.path) {
                return fail("Backup directory must be outside both profiles");
            };
            if !directory.starts_with(root) {
                return fail("Validation backup must remain within disposable root");
            };
            let rid = id();
            let receipt = json!({"id":rid,"phase":"capturing","sourceId":source.id,"destinationId":dest.id,"sourceBrowser":source.browser,"destinationBrowser":dest.browser,"packageID":id(),"packagePath":directory.join(format!("Browser-Bridge-{rid}")),"options":request.get("options").cloned().unwrap_or(json!({"bookmarks":true,"tabs":true,"groups":true,"history":false,"space":"*","limit":50})),"createdAt":now(),"updatedAt":now(),"validationOnly":true});
            self.transaction(|s| {
                s.receipts.push(receipt);
                Ok(())
            })?;
            rid
        };
        let rollback_pending = self.transaction(|s| {
            Ok(s.receipts.iter().any(|r| {
                r["id"] == rid && r["phase"] == "rollingBack" && r["rollbackConsent"] == true
            }))
        })?;
        if rollback_pending {
            drop(lease);
            return self.recover(
                &json!({"command":"rollback","receiptId":rid,"confirmedOwnedChangesRemoval":true}),
            );
        }
        // Explicit Resume may retry a completed error with the same package journal; pending jobs retain their ID.
        self.transaction(|state| {
            let active = state
                .receipts
                .iter()
                .find(|r| r["id"] == rid)
                .and_then(|r| r["activeJob"].as_str())
                .map(str::to_owned);
            if let Some(active) = active {
                if state
                    .jobs
                    .iter()
                    .any(|j| j.id == active && j.result.as_ref().is_some_and(|r| r["ok"] == false))
                {
                    if let Some(receipt) = state.receipts.iter_mut().find(|r| r["id"] == rid) {
                        receipt["activeJob"] = Value::Null;
                    }
                }
            }
            Ok(())
        })?;
        let outcome = self.run_transfer(&rid);
        if let Err(error) = &outcome {
            self.save_receipt(&rid, |r| {
                r["error"] = json!(error.to_string());
                r["paused"] = json!(true);
            })?;
        }
        outcome
    }
    fn run_transfer(&self, rid: &str) -> Result<Value> {
        loop {
            let r = self.transaction(|s| {
                s.receipts
                    .iter()
                    .find(|r| r["id"] == rid)
                    .cloned()
                    .ok_or_else(|| EngineError("Receipt unavailable".into()))
            })?;
            let source = self.connection(field(&r, "sourceId")?)?;
            let dest = self.connection(field(&r, "destinationId")?)?;
            let path = PathBuf::from(field(&r, "packagePath")?);
            let phase = field(&r, "phase")?;
            match phase {
                "capturing" => {
                    let result = self.step(
                        rid,
                        &source.id,
                        "capture",
                        json!({"history":r["options"]["history"]==true}),
                    )?;
                    validate_capture(&result["capture"])?;
                    self.save_receipt(rid, |r| {
                        r["sourceCapture"] = result["capture"].clone();
                        r["phase"] = json!("capturingDestination");
                        r["activeJob"] = Value::Null;
                    })?;
                }
                "capturingDestination" => {
                    let result = self.step(rid, &dest.id, "capture", json!({"history":false}))?;
                    validate_capture(&result["capture"])?;
                    self.save_receipt(rid, |r| {
                        r["destinationCapture"] = result["capture"].clone();
                        r["phase"] = json!("closing");
                        r["activeJob"] = Value::Null;
                    })?;
                }
                "closing" => {
                    platform::normal_close(&source)?;
                    platform::normal_close(&dest)?;
                    self.save_receipt(rid, |r| r["phase"] = json!("backingUp"))?;
                }
                "backingUp" => {
                    if platform::running(&source) || platform::running(&dest) {
                        return fail("Selected browser is still running; close it before backup");
                    };
                    if path.exists() {
                        verify_manifest(&path)?;
                        let capture: Value =
                            serde_json::from_slice(&fs::read(path.join("capture.json"))?)?;
                        let baseline: Value = serde_json::from_slice(&fs::read(
                            path.join("destination-baseline.json"),
                        )?)?;
                        if capture != r["sourceCapture"] || baseline != r["destinationCapture"] {
                            return fail("Backup captures differ from the original receipt");
                        }
                    } else {
                        let staging = path.with_file_name(format!(".Browser-Bridge-{rid}.partial"));
                        if staging.exists() {
                            validate_tree(&staging)?;
                            for entry in walkdir::WalkDir::new(&staging).follow_links(false) {
                                let entry = entry.map_err(|e| EngineError(e.to_string()))?;
                                if entry.file_type().is_symlink() {
                                    return fail("Interrupted backup contains a symlink; retain it for manual inspection");
                                }
                            }
                            fs::remove_dir_all(&staging)?;
                        }
                        private_directory(&staging)?;
                        atomic_json(&staging.join("capture.json"), &r["sourceCapture"])?;
                        atomic_json(
                            &staging.join("destination-baseline.json"),
                            &r["destinationCapture"],
                        )?;
                        atomic_bytes(
                            &staging.join("Bookmarks.html"),
                            html(&r["sourceCapture"]).as_bytes(),
                        )?;
                        copy_profile(&source.path, &staging.join("Source"))?;
                        copy_profile(&dest.path, &staging.join("Destination"))?;
                        write_manifest(&staging)?;
                        fs::rename(&staging, &path)?;
                    }
                    self.save_receipt(rid, |r| {
                        r["phase"] = json!("reopening");
                        r["reopenAfter"] = json!(now());
                    })?;
                }
                "reopening" => {
                    verify_manifest(&path)?;
                    if !platform::running(&dest) {
                        platform::reopen(&dest)?;
                    }
                    let after = r["reopenAfter"].as_u64().unwrap_or(now());
                    let mut ready = false;
                    for _ in 0..120 {
                        let c = self.connection(&dest.id)?;
                        if c.last_seen > after {
                            ready = true;
                            break;
                        }
                        std::thread::sleep(Duration::from_millis(250));
                    }
                    if !ready {
                        return fail("Destination did not reconnect after reopening. Resolve first-run or extension prompts in the exact destination profile, then Resume.");
                    };
                    self.save_receipt(rid, |r| r["phase"] = json!("checkingBeforeImport"))?;
                }
                "checkingBeforeImport" => {
                    let result = self.step(rid, &dest.id, "capture", json!({"history":false}))?;
                    preserved(&r["destinationCapture"], &result["capture"])?;
                    self.save_receipt(rid, |r| {
                        r["phase"] = json!("importing");
                        r["activeJob"] = Value::Null;
                    })?;
                }
                "importing" | "verifying" => {
                    verify_manifest(&path)?;
                    let backed_up: Value =
                        serde_json::from_slice(&fs::read(path.join("capture.json"))?)?;
                    if backed_up != r["sourceCapture"] {
                        return fail("Backed-up capture differs from the original transfer intent");
                    };
                    let payload = json!({"package":{"schema":1,"packageID":r["packageID"],"createdAt":r["createdAt"],"snapshot":r["sourceCapture"]["snapshot"]},"options":r["options"]});
                    let result = self.step(
                        rid,
                        &dest.id,
                        if phase == "importing" {
                            "import"
                        } else {
                            "verify"
                        },
                        payload,
                    )?;
                    if phase == "importing" {
                        let remaining = result["journal"]["remainingTabs"].as_u64().unwrap_or(0);
                        self.save_receipt(rid, |r| {
                            r["activeJob"] = Value::Null;
                            if remaining == 0 {
                                r["phase"] = json!("verifying");
                            }
                        })?;
                    } else {
                        if result["mismatches"]
                            .as_array()
                            .is_none_or(|a| !a.is_empty())
                        {
                            return fail("Independent verification found differences; preserve the package and inspect before rollback");
                        };
                        self.save_receipt(rid,|r|{r["phase"]=json!("checkingDestination");r["verification"]=json!({"mismatchCount":0,"expectedCounts":counts(&result["expected"]),"observedCounts":counts(&result["observed"])});r["activeJob"]=Value::Null;})?;
                    }
                }
                "checkingDestination" => {
                    let result = self.step(rid, &dest.id, "capture", json!({"history":false}))?;
                    preserved(&r["destinationCapture"], &result["capture"])?;
                    return self.save_receipt(rid, |r| {
                        r["phase"] = json!("complete");
                        r["activeJob"] = Value::Null;
                        r["paused"] = json!(false);
                        r["error"] = Value::Null;
                        r["baselinePreserved"] = json!(true);
                    });
                }
                "complete" => return Ok(redact_receipt(&r)),
                _ => {
                    return fail(
                        "Receipt phase requires explicit recovery; no operation was replayed",
                    )
                }
            }
        }
    }
}
fn counts(v: &Value) -> Value {
    let mut counts = serde_json::Map::new();
    if let Some(object) = v.as_object() {
        for (k, v) in object {
            if let Some(a) = v.as_array() {
                counts.insert(k.clone(), json!(a.len()));
            } else if v.is_u64() {
                counts.insert(k.clone(), v.clone());
            }
        }
    }
    Value::Object(counts)
}
fn validate_capture(v: &Value) -> Result<()> {
    if v["schema"] != 1 || v["format"] != "browser-bridge-capture" || !v["snapshot"].is_object() {
        return fail("Connector capture has an unsupported schema");
    };
    for category in ["spaces", "folders", "tabs", "bookmarks", "history"] {
        if !v["snapshot"][category].is_array() {
            return fail("Capture is missing a required portable category");
        }
    }
    Ok(())
}
fn escaped(v: &str) -> String {
    v.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}
fn bookmark_path(nodes: &[Value], node: &Value) -> Vec<String> {
    let mut result = vec![];
    let mut parent = node["parent"].clone();
    let mut seen = std::collections::HashSet::new();
    while let Some(folder) = nodes.iter().find(|n| n["id"] == parent && n["type"] == 2) {
        if !seen.insert(parent.to_string()) {
            break;
        }
        result.push(folder["title"].as_str().unwrap_or("Bookmarks").to_string());
        parent = folder["parent"].clone();
    }
    result.reverse();
    result
}
fn group_path(snapshot: &Value, tab: &Value) -> Vec<String> {
    let mut result = vec![];
    let mut parent = tab["folderID"].clone();
    let mut seen = std::collections::HashSet::new();
    while let Some(folder) = snapshot["folders"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|f| f["id"] == parent && !parent.is_null())
    {
        if !seen.insert(parent.to_string()) {
            break;
        }
        result.push(
            folder["name"]
                .as_str()
                .unwrap_or("Untitled group")
                .to_string(),
        );
        parent = folder["parentID"].clone();
    }
    result.reverse();
    result
}
fn html(capture: &Value) -> String {
    fn bookmarks(
        nodes: &[Value],
        parent: &Value,
        seen: &mut std::collections::HashSet<String>,
        out: &mut String,
    ) {
        for n in nodes.iter().filter(|n| n["parent"] == *parent) {
            let key = n["id"].to_string();
            if !seen.insert(key) {
                continue;
            }
            if n["type"] == 2 {
                out.push_str(&format!(
                    "<DT><H3>{}</H3><DL><p>\n",
                    escaped(n["title"].as_str().unwrap_or("Bookmarks"))
                ));
                bookmarks(nodes, &n["id"], seen, out);
                out.push_str("</DL><p>\n");
            } else {
                link(n, out)
            }
        }
    }
    fn link(n: &Value, out: &mut String) {
        if let Some(url) = n["url"].as_str() {
            if url.starts_with("https://") || url.starts_with("http://") {
                out.push_str(&format!(
                    "<DT><A HREF=\"{}\">{}</A>\n",
                    escaped(url),
                    escaped(n["title"].as_str().unwrap_or(url))
                ))
            }
        }
    }
    let mut out="<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\"><TITLE>Browser Bridge</TITLE><H1>Browser Bridge</H1><DL><p>\n".to_string();
    if let Some(nodes) = capture["snapshot"]["bookmarks"].as_array() {
        let mut seen = std::collections::HashSet::new();
        bookmarks(nodes, &json!(0), &mut seen, &mut out);
        for orphan in nodes
            .iter()
            .filter(|n| !seen.contains(&n["id"].to_string()))
        {
            link(orphan, &mut out);
        }
    }
    out.push_str("<DT><H3>Open tabs</H3><DL><p>\n");
    if let Some(tabs) = capture["snapshot"]["tabs"].as_array() {
        for tab in tabs {
            let group = group_path(&capture["snapshot"], tab);
            let prefix = if tab["essential"] == true {
                "Essentials".to_string()
            } else if tab["pinned"] == true {
                "Pinned tabs".into()
            } else {
                group.join(" / ")
            };
            if !prefix.is_empty() {
                out.push_str(&format!("<DT><H3>{}</H3><DL><p>\n", escaped(&prefix)));
            }
            link(tab, &mut out);
            if !prefix.is_empty() {
                out.push_str("</DL><p>\n");
            }
        }
    }
    out.push_str("</DL><p></DL><p>\n");
    out
}
fn digest(path: &Path) -> Result<String> {
    check_regular(path)?;
    let mut file = File::open(path)?;
    let mut hash = Sha256::new();
    let mut bytes = [0; 65536];
    loop {
        let n = file.read(&mut bytes)?;
        if n == 0 {
            break;
        }
        hash.update(&bytes[..n]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
fn write_manifest(root: &Path) -> Result<()> {
    let mut files = vec![];
    for item in walkdir::WalkDir::new(root).follow_links(false) {
        let item = item.map_err(|e| EngineError(e.to_string()))?;
        if item.file_type().is_symlink() {
            return fail("Backup contains a symlink");
        };
        if item.file_type().is_file() && item.file_name() != "backup-manifest.json" {
            files.push(json!({"path":item.path().strip_prefix(root).unwrap().to_string_lossy(),"sha256":digest(item.path())?}));
        }
    }
    atomic_json(
        &root.join("backup-manifest.json"),
        &json!({"schema":1,"files":files}),
    )
}
fn verify_manifest(root: &Path) -> Result<()> {
    validate_tree(root)?;
    let manifest: Value = serde_json::from_slice(&fs::read(root.join("backup-manifest.json"))?)?;
    for entry in manifest["files"]
        .as_array()
        .ok_or_else(|| EngineError("Backup manifest missing".into()))?
    {
        let relative = Path::new(field(entry, "path")?);
        if relative
            .components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)))
        {
            return fail("Unsafe backup manifest path");
        };
        let file = root.join(relative);
        if digest(&file)? != field(entry, "sha256")? {
            return fail("Backup checksum verification failed; no import was sent");
        }
    }
    Ok(())
}
fn copy_profile(source: &Path, dest: &Path) -> Result<()> {
    validate_tree(source)?;
    for lock in ["SingletonLock", "parent.lock", ".parentlock", "lock"] {
        if fs::symlink_metadata(source.join(lock)).is_ok() {
            return fail("Browser profile lock remains; finish closing the browser before backup");
        }
    }
    private_directory(dest)?;
    for item in walkdir::WalkDir::new(source).follow_links(false) {
        let item = item.map_err(|e| EngineError(e.to_string()))?;
        if item.file_type().is_symlink() {
            return fail(
                "Profile contains symlinks; a safe full backup requires a guided browser export",
            );
        };
        let target = dest.join(item.path().strip_prefix(source).unwrap());
        if item.file_type().is_dir() {
            private_directory(&target)?;
        } else if item.file_type().is_file() {
            check_regular(item.path())?;
            let before = digest(item.path())?;
            fs::copy(item.path(), &target)?;
            if before != digest(item.path())? || before != digest(&target)? {
                return fail("Profile changed during backup; close the browser and retry");
            }
        }
    }
    Ok(())
}
fn preserved(before: &Value, after: &Value) -> Result<()> {
    fn entries(v: &Value) -> Vec<String> {
        let snapshot = &v["snapshot"];
        let mut out = vec![];
        if let Some(nodes) = snapshot["bookmarks"].as_array() {
            for node in nodes {
                if let Some(url) = node["url"].as_str() {
                    out.push(
                        json!(["bookmark", bookmark_path(nodes, node), node["title"], url])
                            .to_string(),
                    );
                }
            }
        }
        if let Some(tabs) = snapshot["tabs"].as_array() {
            for tab in tabs {
                if let Some(url) = tab["url"].as_str() {
                    if url.starts_with("http://") || url.starts_with("https://") {
                        out.push(
                            json!(["tab", url, tab["pinned"] == true, group_path(snapshot, tab)])
                                .to_string(),
                        );
                    }
                }
            }
        }
        out
    }
    let mut after = entries(after);
    for expected in entries(before) {
        if let Some(at) = after.iter().position(|v| v == &expected) {
            after.remove(at);
        } else {
            return fail("Existing destination bookmark path/tab/pin/group was not observed. Transfer paused to preserve its backup; restore the previous browser session before Resume.");
        }
    }
    Ok(())
}

fn checked_backup_base(base: &Path, source: &Path, destination: Option<&Path>) -> Result<PathBuf> {
    if !base.is_absolute() {
        return fail("Choose an absolute backup directory");
    };
    if base
        .components()
        .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return fail("Backup directory cannot contain parent traversal");
    };
    let mut existing = base;
    let mut tail = vec![];
    while !existing.exists() {
        tail.push(
            existing
                .file_name()
                .ok_or_else(|| EngineError("Invalid backup directory".into()))?
                .to_os_string(),
        );
        existing = existing
            .parent()
            .ok_or_else(|| EngineError("Invalid backup directory".into()))?;
    }
    validate_tree(existing)?;
    let mut candidate = existing.canonicalize()?;
    for name in tail.into_iter().rev() {
        candidate.push(name)
    }
    for profile in std::iter::once(source).chain(destination) {
        let profile = profile.canonicalize()?;
        if candidate.starts_with(&profile) || profile.starts_with(&candidate) {
            return fail(
                "Choose a backup directory separate from both browser profiles and their ancestors",
            );
        }
    }
    Ok(candidate)
}
fn selected_capture(mut capture: Value, options: &Value) -> Value {
    let snapshot = &mut capture["snapshot"];
    if options["bookmarks"] == false {
        snapshot["bookmarks"] = json!([])
    }
    if options["tabs"] == false {
        snapshot["tabs"] = json!([])
    }
    if options["history"] != true {
        snapshot["history"] = json!([])
    }
    if options["tabs"] == false || options["groups"] == false {
        snapshot["folders"] = json!([]);
        snapshot["spaces"] = json!([]);
        if let Some(tabs) = snapshot["tabs"].as_array_mut() {
            for tab in tabs {
                tab["folderID"] = Value::Null;
                tab["spaceID"] = Value::Null;
            }
        }
    }
    capture
}
