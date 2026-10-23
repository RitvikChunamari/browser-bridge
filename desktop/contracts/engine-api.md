# Desktop engine boundary

The new portable engine is separate from the existing tested Swift Mac engine during rollout. Do not silently reuse or overwrite Mac state. Reuse schema-1 portable captures and the connector's native protocol; native messages cannot choose filesystem paths or enqueue commands.

Rust crate: `bridge-engine` / module `bridge_engine`.
Public shell seam: cloneable, Send+Sync `Engine::new(root: PathBuf, resources: PathBuf) -> Result<Engine, EngineError>`; `Engine::dispatch(&self, request: serde_json::Value) -> Result<serde_json::Value, EngineError>`. If a constructor name/signature must change, tell the parent before changing it. The shell dispatches through a bounded command allowlist, not arbitrary file/process execution. Native host uses a separate authenticated protocol entry, not the shell command dispatcher.

Requests use `command` with camelCase names. Public shell commands: `status`, `discover`, `installConnector`, `pair`, `plan`, `buildGuidedPackage`, `transfer`, `resume`, `rollback`, `cancel`. Additional sensitive commands are integrated later at this same public journey. Long operations may block their invoking command while separate status calls read persisted progress. File transactions/locks must stay short enough for native polling.

Status returns `{platform, architecture, browsers, connections, receipts, warnings}`. Connections expose id, browser, label, profilePath, connected, capabilities, version and evidence readiness; NEVER authentication secret. Profile discovery returns browser/name/path and supports explicit directories selected by the user. Plan returns readiness, category outcomes and actionable blockers. Production automatic acceptance defaults to empty on Windows/Linux until actual platform/browser evidence passes. A validation CLI may call the complete coordinator only with an explicit disposable root; the renderer exposes no gate bypass.

Pair request: browser + profilePath; result code and expiry, not connector secret. InstallConnector uses browser; host executable/resource locations come from trusted application composition, never extension message fields. Transfer uses sourceId, destinationId, backupDirectory and options. Return a redacted receipt with id, phase, source/destination browser labels, packagePath, timestamps, observed results, warnings and actionable error. Recovery uses receiptId; rollback additionally requires confirmedOwnedChangesRemoval=true.

Capture JSON and native operation semantics match the existing Connector modules. Pair/poll/complete must enforce actual caller browser identity, origin/extension allowlists, expiring pairing and authenticated connection/profile UUID. Browser labels are not identity evidence. Bound input/results and store owner-only state; reject symlink/reparse escapes and concurrent coordinators.

Sensitive follow-up: app/session cryptographic keys stay out of ordinary queues, receipts and logs; store only sealed cookie payloads in durable transport. Consent and selected origins belong to each sensitive transfer. Cookie existence is not authentication proof. Generic HTTP 200 is not a session verification predicate.
