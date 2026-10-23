//! Explicitly consented, origin-scoped cookie transport. Keys and plaintext never enter State.
use super::*;
use aes_gcm::{
    aead::{Aead, KeyInit, Payload},
    Aes256Gcm, Nonce,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use p256::{
    ecdh::EphemeralSecret,
    elliptic_curve::{
        rand_core::{OsRng, RngCore},
        sec1::ToEncodedPoint,
    },
    PublicKey,
};
use sha2::Sha256;
use zeroize::Zeroizing;
const OPS: &[&str] = &[
    "cookies.prepare",
    "cookies.capture",
    "cookies.apply",
    "cookies.verify",
    "cookies.cleanup",
];
pub(crate) fn operation(operation: &str) -> bool {
    OPS.contains(&operation)
}
fn origins(v: &Value) -> Result<Vec<String>> {
    let values = v["origins"]
        .as_array()
        .ok_or_else(|| EngineError("Select exact origins".into()))?;
    if values.is_empty() || values.len() > 20 {
        return fail("Select between one and twenty exact origins");
    };
    let mut result = vec![];
    for value in values {
        let text = value
            .as_str()
            .ok_or_else(|| EngineError("Origin must be text".into()))?;
        let url = url::Url::parse(text).map_err(|_| EngineError("Invalid origin".into()))?;
        let loopback = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
        if !(url.scheme() == "https" || url.scheme() == "http" && loopback)
            || url.path() != "/"
            || url.query().is_some()
            || url.fragment().is_some()
            || !url.username().is_empty()
            || url.password().is_some()
        {
            return fail("Use exact HTTPS origins without paths, credentials or wildcards (HTTP is allowed only for loopback fixtures)");
        };
        if url.scheme() == "https" && url.port().is_some() {
            return fail("Cookies do not isolate ports; use the default HTTPS origin");
        };
        let origin = url.origin().ascii_serialization();
        if !result.contains(&origin) {
            result.push(origin)
        }
    }
    result.sort();
    Ok(result)
}
pub(crate) fn validate_result(operation: &str, result: &Value) -> Result<()> {
    if !self::operation(operation) {
        return Ok(());
    }
    if !result["ok"].is_boolean() {
        return fail("Sensitive result status must be boolean");
    };
    if result["ok"] == false {
        if result
            .as_object()
            .is_none_or(|m| m.keys().any(|k| !["ok", "error"].contains(&k.as_str())))
        {
            return fail("Unexpected sensitive error fields");
        };
        return Ok(());
    }
    let allowed = match operation {
        "cookies.capture" => vec!["ok", "sealed", "count"],
        "cookies.prepare" => vec!["ok", "publicKey"],
        "cookies.apply" => vec!["ok", "applied", "existing"],
        "cookies.verify" => vec!["ok", "verified", "missing"],
        _ => vec!["ok", "cleaned"],
    };
    if result
        .as_object()
        .is_none_or(|m| m.keys().any(|k| !allowed.contains(&k.as_str())))
    {
        return fail("Unsealed sensitive result rejected before persistence");
    };
    if operation == "cookies.capture" {
        let sealed = &result["sealed"];
        if sealed.as_object().is_none_or(|m| {
            m.keys()
                .any(|k| !["publicKey", "nonce", "ciphertext"].contains(&k.as_str()))
        }) {
            return fail("Invalid sealed envelope");
        };
        for field in ["publicKey", "nonce", "ciphertext"] {
            if !sealed[field].is_string() {
                return fail("Sealed envelope is incomplete");
            }
        }
    }
    Ok(())
}
fn context(id: &str, role: &str, origins: &[String]) -> Vec<u8> {
    format!(
        "browser-bridge-cookie-v1|{id}|{role}|{}",
        origins.join("\n")
    )
    .into_bytes()
}
fn key(secret: &EphemeralSecret, public: &str, aad: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
    let public = B64
        .decode(public)
        .map_err(|_| EngineError("Invalid ephemeral public key".into()))?;
    let public = PublicKey::from_sec1_bytes(&public)
        .map_err(|_| EngineError("Invalid ephemeral public key".into()))?;
    let shared = secret.diffie_hellman(&public);
    let mut key = Zeroizing::new([0u8; 32]);
    hkdf::Hkdf::<Sha256>::new(Some(b"browser-bridge-cookie-v1"), shared.raw_secret_bytes())
        .expand(aad, key.as_mut())
        .map_err(|_| EngineError("Key derivation failed".into()))?;
    Ok(key)
}
fn open(secret: &EphemeralSecret, envelope: &Value, aad: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    let key = key(secret, field(envelope, "publicKey")?, aad)?;
    let nonce = B64
        .decode(field(envelope, "nonce")?)
        .map_err(|_| EngineError("Invalid nonce".into()))?;
    if nonce.len() != 12 {
        return fail("Invalid nonce length");
    };
    let ciphertext = B64
        .decode(field(envelope, "ciphertext")?)
        .map_err(|_| EngineError("Invalid sealed payload".into()))?;
    let clear = Aes256Gcm::new_from_slice(key.as_ref())
        .map_err(|_| EngineError("Invalid key".into()))?
        .decrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: &ciphertext,
                aad,
            },
        )
        .map_err(|_| {
            EngineError(
                "Cookie envelope authentication failed; restage with renewed consent".into(),
            )
        })?;
    Ok(Zeroizing::new(clear))
}
fn seal(secret: &EphemeralSecret, public: &str, clear: &[u8], aad: &[u8]) -> Result<Value> {
    let key = key(secret, public, aad)?;
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut nonce);
    let ciphertext = Aes256Gcm::new_from_slice(key.as_ref())
        .map_err(|_| EngineError("Invalid key".into()))?
        .encrypt(Nonce::from_slice(&nonce), Payload { msg: clear, aad })
        .map_err(|_| EngineError("Cookie sealing failed".into()))?;
    Ok(
        json!({"publicKey":B64.encode(secret.public_key().to_encoded_point(false).as_bytes()),"nonce":B64.encode(nonce),"ciphertext":B64.encode(ciphertext)}),
    )
}
impl Engine {
    pub(crate) fn sessions_dispatch(&self, v: &Value) -> Result<Value> {
        match field(v, "command")? {
            "sessions.plan" => {
                let origins = origins(v)?;
                Ok(
                    json!({"eligible":false,"readiness":"unverified","origins":origins,"blockers":["No real browser/OS session route has passed acceptance. Use a browser-managed sign-in flow; disposable validation is available to contributors."],"warnings":["Cookie verification is not proof of signed-in authentication.","Conflicting destination cookies, domain-wide cookies, partitions and containers are blocked.","Grant cookies and only the selected origins in each browser connector using its permission button."]}),
                )
            }
            "sessions.start" | "sessions.retry" => {
                if v["consent"] != true {
                    return fail(
                        "Explicit consent is required for each sensitive transfer or restaging",
                    );
                }
                fail("Session transfer remains gated pending real browser/OS acceptance. No cookies were captured or changed.")
            }
            "sessions.status" => self.transaction(|s| {
                let sessions = s
                    .sessions
                    .iter()
                    .filter(|r| v["sessionId"].is_null() || r["id"] == v["sessionId"])
                    .cloned()
                    .collect::<Vec<_>>();
                Ok(json!({"sessions":sessions}))
            }),
            "sessions.confirm" => self.transaction(|s| {
                let r = s
                    .sessions
                    .iter_mut()
                    .find(|r| r["id"] == v["sessionId"])
                    .ok_or_else(|| EngineError("Unknown sensitive transfer".into()))?;
                if r["phase"] != "cookiesVerified" {
                    return fail("Verify cookies before confirming sign-in");
                };
                let confirmed = v["confirmedSignedIn"]
                    .as_bool()
                    .ok_or_else(|| EngineError("Explicit sign-in confirmation required".into()))?;
                r["sessionOutcome"] = json!(if confirmed {
                    "userConfirmed"
                } else {
                    "reloginRequired"
                });
                r["verificationMethod"] = json!("userConfirmation");
                Ok(r.clone())
            }),
            "sessions.cleanup" => self.cleanup_session(field(v, "sessionId")?),
            _ => fail("Unknown session command"),
        }
    }
    fn cleanup_session(&self, id: &str) -> Result<Value> {
        let lease = open_private(&self.root.join("sensitive.lock"))?;
        lease.try_lock_exclusive().map_err(|_|EngineError("A sensitive transfer is running. Wait for its outcome before cleanup; no in-flight operation was unlocked.".into()))?;
        let row=self.transaction(|s|{let row=s.sessions.iter().find(|r|r["id"]==id).cloned().ok_or_else(||EngineError("Unknown sensitive transfer".into()))?;if s.jobs.iter().any(|j|j.payload["sessionId"]==id&&j.result.is_none()&&j.claimed){return fail("A sensitive operation is still claimed and may finish. Reconnect the original connector before cleanup; no in-flight operation was discarded.")};s.jobs.retain(|j|j.payload["sessionId"]!=id);Ok(row)})?;
        for connection in [field(&row, "sourceId")?, field(&row, "destinationId")?] {
            let job = self.enqueue(
                connection,
                "cookies.cleanup",
                json!({"sessionId":id,"origins":row["origins"]}),
            )?;
            self.wait_job(&job)?;
        }
        self.transaction(|s| {
            s.jobs.retain(|j| j.payload["sessionId"] != id);
            let row = s.sessions.iter_mut().find(|r| r["id"] == id).unwrap();
            row["sealedTransportCleaned"] = json!(true);
            row["error"] = Value::Null;
            Ok(row.clone())
        })
    }
    /// Trusted contributor seam. Every connected filesystem profile and state root must be disposable.
    pub fn validate_session(&self, mut request: Value, disposable_root: &Path) -> Result<Value> {
        self.validate_disposable(disposable_root)?;
        if request["command"] == "sessions.retry" {
            if request["consent"] != true {
                return fail("Renew consent before restaging");
            };
            let old = self.cleanup_session(field(&request, "sessionId")?)?;
            request = json!({"sourceId":old["sourceId"],"destinationId":old["destinationId"],"origins":old["origins"],"consent":true});
        }
        if request["command"] == "sessions.cleanup" {
            return self.sessions_dispatch(&request);
        }
        if request["consent"] != true {
            return fail("Explicit per-transfer cookie consent is required");
        };
        let origins = origins(&request)?;
        let source = field(&request, "sourceId")?;
        let destination = field(&request, "destinationId")?;
        if source == destination {
            return fail("Select distinct connected profiles");
        };
        self.transaction(|s| {
            if ![source, destination]
                .iter()
                .all(|id| s.connections.iter().any(|c| c.id == *id))
            {
                return fail("Pair both exact profiles first");
            };
            Ok(())
        })?;
        let session = id();
        let lease = open_private(&self.root.join("sensitive.lock"))?;
        lease
            .try_lock_exclusive()
            .map_err(|_| EngineError("Another sensitive transfer is running".into()))?;
        self.transaction(|s|{s.sessions.push(json!({"id":session,"sourceId":source,"destinationId":destination,"origins":origins,"phase":"preparing","sessionOutcome":"unverified","createdAt":now(),"validationOnly":true}));Ok(())})?;
        let secret = EphemeralSecret::random(&mut OsRng);
        let public = B64.encode(secret.public_key().to_encoded_point(false).as_bytes());
        let run = (|| -> Result<Value> {
            let job = self.enqueue(
                destination,
                "cookies.prepare",
                json!({"sessionId":session,"origins":origins}),
            )?;
            let prepared = self.wait_job(&job)?;
            let job = self.enqueue(
                source,
                "cookies.capture",
                json!({"sessionId":session,"origins":origins,"publicKey":public}),
            )?;
            let captured = self.wait_job(&job)?;
            let clear = open(
                &secret,
                &captured["sealed"],
                &context(&session, "source", &origins),
            )?;
            if clear.len() > 256 * 1024 {
                return fail("Selected cookie payload exceeds the 256 KiB limit");
            };
            let sealed = seal(
                &secret,
                field(&prepared, "publicKey")?,
                &clear,
                &context(&session, "destination", &origins),
            )?;
            drop(clear);
            let job = self.enqueue(
                destination,
                "cookies.apply",
                json!({"sessionId":session,"origins":origins,"sealed":sealed}),
            )?;
            let applied = self.wait_job(&job)?;
            let job = self.enqueue(
                destination,
                "cookies.verify",
                json!({"sessionId":session,"origins":origins}),
            )?;
            let verified = self.wait_job(&job)?;
            if verified["missing"].as_u64() != Some(0) {
                return fail(
                    "Independent cookie verification found differences; sign in again if needed",
                );
            };
            self.transaction(|s|{let r=s.sessions.iter_mut().find(|r|r["id"]==session).unwrap();r["phase"]=json!("cookiesVerified");r["cookies"]=json!({"captured":captured["count"],"applied":applied["applied"],"existing":applied["existing"],"verified":verified["verified"]});r["sessionOutcome"]=json!("unverified");r["notice"]=json!("Cookie fields were observed independently. Authentication is not established until an explicit site predicate or user confirmation.");Ok(r.clone())})
        })();
        drop(secret);
        if run.is_err() {
            self.transaction(|s|{let r=s.sessions.iter_mut().find(|r|r["id"]==session).unwrap();r["phase"]=json!("restagingRequired");r["error"]=json!("Sensitive step interrupted or unsupported. Ephemeral keys were discarded; review destination sign-in and restage with renewed consent.");r["sessionOutcome"]=json!("unverified");Ok(())})?;
        }
        run
    }
}

pub(crate) fn sanitize_result(operation: &str, result: &Value) -> Result<Value> {
    validate_result(operation, result)?;
    if !self::operation(operation) {
        return Ok(result.clone());
    }
    if result["ok"] == false {
        return Ok(
            json!({"ok":false,"error":"Sensitive connector operation requires renewed permission or restaging; no cookie values are included in this report."}),
        );
    }
    if operation == "cookies.cleanup" && !result["cleaned"].is_boolean() {
        return fail("Cleanup result must be boolean");
    };
    for (field, value) in result.as_object().into_iter().flatten() {
        if ["count", "applied", "existing", "verified", "missing"].contains(&field.as_str())
            && !value.is_u64()
        {
            return fail("Sensitive counts must be unsigned numbers");
        }
        if field == "publicKey" {
            let key = B64
                .decode(
                    value
                        .as_str()
                        .ok_or_else(|| EngineError("Invalid ephemeral key".into()))?,
                )
                .map_err(|_| EngineError("Invalid ephemeral key".into()))?;
            if key.len() != 65 {
                return fail("Invalid ephemeral key length");
            }
        }
    }
    if operation == "cookies.capture" {
        for key in ["publicKey", "nonce", "ciphertext"] {
            let bytes = B64
                .decode(field(&result["sealed"], key)?)
                .map_err(|_| EngineError("Invalid sealed envelope encoding".into()))?;
            if bytes.len() > 350_000 {
                return fail("Sealed cookie payload too large");
            }
        }
    }
    Ok(result.clone())
}
