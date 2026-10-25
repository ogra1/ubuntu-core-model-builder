//! The authentication core: Ubuntu One SSO login for the Snap Store.
//!
//! ## Protocol (mirrors `snapcraft` → `craft_store/login/_ubuntuone.py`)
//!
//! 1. **Root macaroon** — `POST {store}/dev/api/acl/`
//!    body `{"permissions": [...], "ttl": <sec>}` → `{"macaroon": "<v1 binary>"}`.
//!    The root macaroon carries a third-party caveat whose location is the
//!    SSO discharge endpoint and whose `cid` is the `caveat_id`.
//!
//! 2. **Discharge** — `POST {login}/api/v2/tokens/discharge`
//!    body `{"email", "password", "caveat_id", ["otp"]}` →
//!    `{"discharge_macaroon": "..."}`.
//!
//!    Accounts with 2FA enabled get **HTTP 401** and a JSON body containing
//!    `error_list: [{"code": "twofactor-required", ...}]` (or a
//!    `TWOFACTOR_REQUIRED` top-level code) when no valid `otp` is supplied.
//!    The state machine pauses here and asks the UI for a code.
//!
//! 3. **Bind** — the discharge macaroon is bound to the root with the
//!    `HashSignaturesBinder` algorithm
//!    (see [`crate::macaroon::Macaroon::bind_discharge_signature`]) and the
//!    request header becomes `Macaroon root={root}, discharge={bound}`.
//!
//! 4. **Persist** — the pair goes through [`crate::storage::CredentialsStore`]
//!    and is returned to Dart in `MachineEvent::Succeeded.credentials_json`
//!    for Flutter Secure Storage.
//!
//! ## Concurrency model
//!
//! One driver task per [`AuthRuntime`], on a multithreaded Tokio runtime
//! (created once by the FFI layer — see [`crate::runtime`]). The driver is a
//! `match` loop over [`MachineState`] that only ever *awaits* network I/O or
//! the UI command channel — it never blocks a thread, so the Flutter UI
//! main thread is never held. Commands arrive through an unbounded channel
//! (synchronous `send` from any thread); events are buffered in an
//! [`EventBuffer`](crate::state::EventBuffer) that Dart polls via
//! `drain_events()` (or subscribes to in a push wrapper).

use crate::error::{AuthenticationError, Result};
use crate::macaroon::Macaroon;
use base64::{Engine, engine::general_purpose};
use crate::state::{
    AuthStateMachine, EventBuffer, MachineEvent, MachineState, UiEvent,
};
use crate::storage::{Credentials, CredentialsStore, InMemoryStore};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

/// Default Snap Store base URL (`dashboard.snapcraft.io`).
pub const DEFAULT_STORE_URL: &str = "https://dashboard.snapcraft.io";
/// Default Ubuntu One SSO base URL (`login.ubuntu.com`).
pub const DEFAULT_LOGIN_URL: &str = "https://login.ubuntu.com";
/// Macaroon time-to-live in seconds (24 h — same default as `snapcraft`).
pub const DEFAULT_TTL: u64 = 86_400;
/// Secure-storage key used for the default session.
pub const DEFAULT_STORAGE_KEY: &str = "snapstore-credentials";

/// Full read/write Snap Store token — the ACL set `snapcraft login` requests,
/// **plus** `store_admin` (brand-store catalog, `GET /api/v2/stores/{id}/snaps`)
/// and `modify_account_key` (key registration,
/// `POST /dev/api/account/account-key`).
///
/// Neither of those two is part of the plain `snapcraft login` set: snapcraft
/// obtains `store_admin` via `export-login --acls ...store_admin` and scopes
/// key registration to a short-lived `modify_account_key` token. We fold both
/// into the single in-app login so one sign-in covers every endpoint the app
/// calls (search / account / keys / brand-store catalog).
pub const DEFAULT_PERMISSIONS: [&str; 9] = [
    "package_access",
    "package_manage",
    "package_metrics",
    "package_push",
    "package_register",
    "package_release",
    "package_update",
    "store_admin",
    "modify_account_key",
];

/// Read-only token (e.g. for a client that only lists/inspects snaps).
pub const VIEW_PERMISSIONS: [&str; 1] = ["account-view-packages"];

/// Account information returned by the store's `whoami` endpoint
/// (`GET {store}/api/v2/tokens/whoami`).
///
/// Shape (what `snapcraft whoami` prints from):
/// ```json
/// {
///   "account": {
///     "id": "<developer/account id>",
///     "email": "user@example.com",
///     "username": "user",
///     "display-name": "User Name"
///   },
///   "permissions": ["package_access", "..."],
///   "channels": null,
///   "expires": "2026-10-15T12:00:00+00:00"
/// }
/// ```
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct AccountInfo {
    /// Developer/account id — the `brand-id` for model assertions.
    pub id: String,
    /// Account email.
    pub email: String,
    /// Account username.
    pub username: String,
    /// Human-readable display name (may be empty).
    pub display_name: String,
    /// ACLs the persisted macaroon was granted (empty = unrestricted).
    pub permissions: Vec<String>,
    /// Channel restrictions (empty = unrestricted).
    pub channels: Vec<String>,
    /// Macaroon expiry, ISO-8601 (empty when unknown).
    pub expires: String,
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Configuration for an [`AuthRuntime`].
#[derive(Clone)]
pub struct AuthConfig {
    /// Store base URL, e.g. `https://dashboard.snapcraft.io`.
    pub store_url: String,
    /// SSO base URL, e.g. `https://login.ubuntu.com`.
    pub login_url: String,
    /// Permissions (attenuations) requested on the root macaroon.
    pub permissions: Vec<String>,
    /// Optional channel restrictions.
    pub channels: Option<Vec<String>>,
    /// Optional package restrictions (`{"type": "snap", "name": "..."}`).
    pub packages: Option<Vec<serde_json::Value>>,
    /// Macaroon TTL in seconds.
    pub ttl: u64,
    /// Client description attached to the session, e.g. `"my-app@phone"`.
    pub description: String,
    /// Per-request HTTP timeout.
    pub timeout: Duration,
    /// `User-Agent` header.
    pub user_agent: String,
    /// Where the resulting credentials are persisted.
    pub store: Arc<dyn CredentialsStore>,
    /// Secure-storage key the credentials are saved under.
    pub storage_key: String,
}

impl std::fmt::Debug for AuthConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AuthConfig")
            .field("store_url", &self.store_url)
            .field("login_url", &self.login_url)
            .field("permissions", &self.permissions)
            .field("ttl", &self.ttl)
            .field("storage_key", &self.storage_key)
            .finish()
    }
}

impl Default for AuthConfig {
    fn default() -> Self {
        AuthConfig {
            store_url: DEFAULT_STORE_URL.to_string(),
            login_url: DEFAULT_LOGIN_URL.to_string(),
            permissions: DEFAULT_PERMISSIONS.iter().map(|s| s.to_string()).collect(),
            channels: None,
            packages: None,
            ttl: DEFAULT_TTL,
            description: "rust-snapstore-auth".to_string(),
            timeout: Duration::from_secs(30),
            user_agent: "rust-snapstore-auth/0.1 (flutter)".to_string(),
            store: Arc::new(InMemoryStore::new()),
            storage_key: DEFAULT_STORAGE_KEY.to_string(),
        }
    }
}

// ---------------------------------------------------------------------------
// The runtime (FFI-facing handle)
// ---------------------------------------------------------------------------

/// A live authentication runtime.
///
/// Keep **one instance** per app (or per store). Every method is `&self`
/// and safe to call from any thread — the FFI boundary is a foreign thread
/// and all state changes are routed through channels to the driver task.
pub struct AuthRuntime {
    config: AuthConfig,
    cmd: Mutex<tokio::sync::mpsc::UnboundedSender<UiEvent>>,
    state: crate::state::SharedState,
    events: EventBuffer,
    http: reqwest::Client,
    driver_alive: Arc<AtomicBool>,
}

impl AuthRuntime {
    /// Spawn the runtime and its driver task on the *current* Tokio
    /// runtime (the FFI layer creates one — see [`crate::runtime`]).
    ///
    /// Must be called from within a Tokio context.
    pub fn spawn(config: AuthConfig) -> Self {
        let state: crate::state::SharedState = Arc::new(Mutex::new(MachineState::Idle));
        let (cmd_tx, cmd_rx) = tokio::sync::mpsc::unbounded_channel::<UiEvent>();
        let (event_tx, _event_rx) = tokio::sync::mpsc::unbounded_channel::<MachineEvent>();
        // `_event_rx` is deliberately dropped: consumers pull from the
        // shared buffer. The tx half must outlive the machine, so we park
        // it inside the machine's emit path via a leak-free holder:
        // (the machine keeps it; see AuthStateMachine::new signature).

        let buffer = EventBuffer::new();

        let driver_alive = Arc::new(AtomicBool::new(true));
        let machine = Arc::new(AuthStateMachine::new(
            Arc::clone(&state),
            event_tx,
            buffer.clone(),
        ));
        let http = build_http_client(&config);
        // Owned clones for the task (references must not cross `spawn`).
        let task_http = http.clone();
        let task_config = config.clone();
        let machine_for_driver = Arc::clone(&machine);
        let alive_clone = Arc::clone(&driver_alive);

        let driver = tokio::spawn(async move {
            let mut cmd_rx = cmd_rx;
            run_driver(&machine_for_driver, &task_http, &task_config, &mut cmd_rx, &alive_clone)
                .await;
            // Safety net: if the loop exits, the runtime is idle again.
            if alive_clone.load(Ordering::SeqCst) {
                machine_for_driver.set_state(MachineState::Idle);
            }
        });

        // Keep the JoinHandle in a process-global slot: one runtime per app
        // is the documented usage, and the handle must outlive the runtime
        // (dropping it would close the command channel).
        register_driver(driver);

        AuthRuntime {
            config,
            cmd: Mutex::new(cmd_tx),
            state,
            events: buffer,
            http,
            driver_alive,
        }
    }

    // -- state / events ----------------------------------------------------

    /// Current machine state (non-blocking).
    pub fn state(&self) -> MachineState {
        *self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Number of unread machine events.
    pub fn pending_event_count(&self) -> usize {
        self.events.len()
    }

    /// Drain all machine events produced since the last call.
    ///
    /// Returns the JSON encoding of each event, one per line (`\n` joined);
    /// empty string when there are none. Pull model for Dart: call after
    /// every command, plus on a short timer (100–300 ms) for a push feel.
    pub fn drain_events(&self) -> String {
        let mut out = String::new();
        while let Some(e) = self.events.pop() {
            // MachineEvent is fully serializable; this cannot fail.
            if let Ok(s) = serde_json::to_string(&e) {
                if !out.is_empty() {
                    out.push('\n');
                }
                out.push_str(&s);
            }
        }
        out
    }

    // -- UI → Rust commands ------------------------------------------------

    fn send(&self, event: UiEvent) -> Result<()> {
        let guard = self.cmd.lock().unwrap_or_else(PoisonError::into_inner);
        guard
            .send(event)
            .map_err(|_| AuthenticationError::NoActiveSession)
    }

    /// Begin the login flow (state must be `Idle`).
    pub fn start_login(&self) -> Result<()> {
        self.send(UiEvent::StartLogin {
            description: self.config.description.clone(),
        })
    }

    /// Submit email + password (state must be `NeedsCredentials`).
    ///
    /// The password is only ever held in memory for the duration of the
    /// discharge request(s); it is never written to storage or logs.
    pub fn submit_credentials(&self, email: &str, password: &str) -> Result<()> {
        self.send(UiEvent::Credentials {
            email: email.to_string(),
            password: password.to_string(),
        })
    }

    /// Submit the 2FA one-time code (state must be `Needs2FACode`).
    pub fn submit_2fa_code(&self, code: &str) -> Result<()> {
        self.send(UiEvent::TwoFactorCode {
            code: code.to_string(),
        })
    }

    /// Restore persisted credentials after an app relaunch (state `Idle`).
    ///
    /// `json` is exactly the string carried by
    /// `MachineEvent::Succeeded.credentials_json`. The pair is validated
    /// (parse + bind) before the machine marks the session `Succeeded`.
    pub fn restore_credentials(&self, json: &str) -> Result<()> {
        self.send(UiEvent::RestoreCredentials {
            json: json.to_string(),
        })
    }

    /// End the session and clear persisted credentials
    /// (state must be `Succeeded`).
    pub fn logout(&self) -> Result<()> {
        self.send(UiEvent::Logout)
    }

    /// Abort the current flow (any state).
    pub fn cancel(&self) -> Result<()> {
        self.send(UiEvent::Cancel)
    }

    // -- authenticated API helpers ------------------------------------------

    /// Build the `Authorization` header value for store API calls from the
    /// persisted credentials.
    pub fn authorization_header(&self) -> Result<String> {
        let creds = self.load_persisted()?;
        build_macaroon_header(&creds)
    }

    /// `GET {store}/api/v2/tokens/whoami` using the persisted credentials.
    ///
    /// Await from an async context (the FFI layer blocks on the shared
    /// runtime and hands the result to Dart as JSON).
    pub async fn whoami(&self) -> Result<AccountInfo> {
        let header = self.authorization_header()?;
        let url = format!(
            "{}/api/v2/tokens/whoami",
            self.config.store_url.trim_end_matches('/')
        );
        let v = self.http_json(&url, Some(&header), None).await?;
        parse_account_info(&v)
    }

    /// `GET {store}/dev/api/account` — the full account object.
    ///
    /// This is the endpoint `snapcraft keys` uses (registered keys:
    /// `account_keys[].public-key-sha3-384`) and the one surl-based brand
    /// store listings query (`stores[].{id,name,roles}`). Also carries
    /// `account_id`, `snaps[]` (registered snap names) and friends.
    pub async fn account_info(&self) -> Result<serde_json::Value> {
        let header = self.authorization_header()?;
        let url = format!(
            "{}/dev/api/account",
            self.config.store_url.trim_end_matches('/')
        );
        self.http_json(&url, Some(&header), None).await
    }

    /// `POST {store}/dev/api/account/account-key` — register a serialized
    /// `account-key` assertion (what `snapcraft register-key` submits).
    ///
    /// The assertion itself is produced on the host with
    /// `snap export-key <name> <account-id>` (local GPG keyring); this call
    /// only uploads it.
    pub async fn register_key(&self, account_key_request: String) -> Result<()> {
        let header = self.authorization_header()?;
        let url = format!(
            "{}/dev/api/account/account-key",
            self.config.store_url.trim_end_matches('/')
        );
        let body = serde_json::json!({ "account_key_request": account_key_request });
        self.http_json(&url, Some(&header), Some(&body)).await?;
        Ok(())
    }

    /// Send a JSON request with the given `Authorization` header and return
    /// the parsed 2xx body. `POST` when [body] is `Some`.
    async fn http_json(
        &self,
        url: &str,
        authorization: Option<&str>,
        body: Option<&serde_json::Value>,
    ) -> Result<serde_json::Value> {
        let mut req = match body {
            Some(b) => self.http.post(url).json(b),
            None => self.http.get(url),
        };
        if let Some(h) = authorization {
            req = req.header("Authorization", h);
        }
        let resp = req.send().await?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            let (msg, code) = parse_error_body(&body, status.as_u16());
            return Err(AuthenticationError::Http {
                status: status.as_u16(),
                message: format!("{msg} (code: {code})"),
            });
        }
        resp.json()
            .await
            .map_err(|e| AuthenticationError::InvalidResponse(format!("bad JSON response: {e}")))
    }


    /// `GET {store}/api/v2/stores/{store_id}/snaps` — the catalog of a
    /// (brand) store: `{"snaps": [{"name", "id", ...}]}`.
    ///
    /// The store's ACL check is done against the macaroon's caveats: a token
    /// carrying `store_admin` (or the account owning the store) lists the
    /// snaps; anything else yields a 403 `Http` error.
    pub async fn store_snaps(&self, store_id: &str) -> Result<serde_json::Value> {
        let header = self.authorization_header()?;
        let url = format!(
            "{}/api/v2/stores/{}/snaps",
            self.config.store_url.trim_end_matches('/'),
            store_id
        );
        self.http_json(&url, Some(&header), None).await
    }

    /// Import credentials previously exported with
    /// `snapcraft export-login --acls <acls> <file>`.
    ///
    /// The file content is base64 of `{"t": "u1-macaroon",
    /// "v": {"r": <root>, "d": <discharge>}}`. The decoded pair is fed
    /// through the existing `UiEvent::RestoreCredentials` command so the
    /// state machine remains the single source of truth: it validates
    /// (parse + bind), persists, transitions to `Succeeded` and emits a
    /// `Succeeded` event carrying the `credentials_json` for Flutter Secure
    /// Storage. Decoding errors are returned synchronously; validation
    /// errors arrive asynchronously as a `Failed` event.
    pub fn import_exported_login(&self, raw: &str) -> Result<()> {
        let text = raw.trim();
        let b64 = general_purpose::STANDARD
            .decode(text)
            .or_else(|_| general_purpose::STANDARD_NO_PAD.decode(text))
            .or_else(|_| general_purpose::URL_SAFE_NO_PAD.decode(text))
            .map_err(|e| {
                AuthenticationError::InvalidResponse(format!(
                    "exported credentials are not valid base64: {e}"
                ))
            })?;
        let v: serde_json::Value = serde_json::from_slice(&b64).map_err(|e| {
            AuthenticationError::InvalidResponse(format!(
                "could not decode exported credentials: {e}"
            ))
        })?;
        let inner = v
            .get("v")
            .ok_or_else(|| {
                AuthenticationError::InvalidResponse(
                    "unexpected export format (missing v field)".into(),
                )
            })?
            .as_object()
            .ok_or_else(|| {
                AuthenticationError::InvalidResponse(
                    "unexpected export format (v is not an object)".into(),
                )
            })?;
        let root = inner
            .get("r")
            .and_then(|x| x.as_str())
            .ok_or_else(|| {
                AuthenticationError::InvalidResponse(
                    "unexpected export format (missing root macaroon)".into(),
                )
            })?
            .to_string();
        let discharge = inner
            .get("d")
            .and_then(|x| x.as_str())
            .ok_or_else(|| {
                AuthenticationError::InvalidResponse(
                    "unexpected export format (missing discharge macaroon)".into(),
                )
            })?
            .to_string();
        let creds = Credentials { root, discharge };
        // Validate before enqueuing so obvious garbage fails synchronously.
        build_macaroon_header(&creds)?;
        let json = serde_json::to_string(&creds).map_err(|e| {
            AuthenticationError::InvalidResponse(format!("encode credentials: {e}"))
        })?;
        self.send(UiEvent::RestoreCredentials { json })
    }

    fn load_persisted(&self) -> Result<Credentials> {
        self.config
            .store
            .load(&self.config.storage_key)
            .map_err(|e| AuthenticationError::Storage(e.to_string()))?
            .ok_or(AuthenticationError::NoActiveSession)
    }
}

impl Drop for AuthRuntime {
    fn drop(&mut self) {
        // Stop the driver: it observes the flag, and dropping this handle
        // also closes the command channel, unblocking a parked driver.
        self.driver_alive.store(false, Ordering::SeqCst);
    }
}

/// Process-global slot holding the driver task's JoinHandle (see
/// [`AuthRuntime::spawn`]). One runtime per app is the documented usage.
static DRIVER: std::sync::OnceLock<std::sync::Mutex<Option<tokio::task::JoinHandle<()>>>> =
    std::sync::OnceLock::new();

fn register_driver(handle: tokio::task::JoinHandle<()>) {
    let slot = DRIVER.get_or_init(|| std::sync::Mutex::new(None));
    let mut guard = slot.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(old) = guard.replace(handle) {
        if !old.is_finished() {
            // A second runtime was created while the first is still live:
            // abort the stale driver so its channel closes cleanly.
            old.abort();
        }
    }
}


fn build_http_client(config: &AuthConfig) -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(config.timeout)
        .user_agent(config.user_agent.clone())
        .build()
        // Client construction only fails on programmer error (e.g. a
        // negative timeout); a panic here is acceptable and cannot cross
        // the FFI boundary at runtime.
        .expect("reqwest client construction")
}

// ---------------------------------------------------------------------------
// Driver — the actual interactive state machine
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
async fn run_driver(
    machine: &AuthStateMachine,
    http: &reqwest::Client,
    config: &AuthConfig,
    cmd_rx: &mut tokio::sync::mpsc::UnboundedReceiver<UiEvent>,
    alive: &Arc<AtomicBool>,
) {
    // `machine` is an Arc to allow the task to own its lifetime; the
    // driver is its only mutator (state transitions + emits).
    loop {
        if !alive.load(Ordering::SeqCst) {
            return;
        }
        match machine.state() {
            // --------------------------------------------------------- Idle
            MachineState::Idle => match cmd_rx.recv().await {
                Some(UiEvent::StartLogin { description }) => {
                    let _ = description; // informational; stored on config
                    if let Err(e) = machine.transition(
                        &[MachineState::Idle],
                        MachineState::NeedsCredentials,
                    ) {
                        machine.fail(e);
                        continue;
                    }
                    machine.emit(MachineEvent::NeedsCredentials);
                }
                Some(UiEvent::RestoreCredentials { json }) => {
                    let outcome: Result<()> = (|| {
                        let creds: Credentials = serde_json::from_str(&json)
                            .map_err(|e| AuthenticationError::Storage(format!("bad credentials JSON: {e}")))?;
                        // Validate: parse both macaroons + bind.
                        build_macaroon_header(&creds)?;
                        // Re-persist so authorization_header() works.
                        config
                            .store
                            .save(&config.storage_key, &creds)
                            .map_err(|e| AuthenticationError::Storage(e.to_string()))?;
                        Ok(())
                    })();
                    match outcome {
                        Ok(()) => {
                            if let Err(e) = machine.transition(
                                &[MachineState::Idle],
                                MachineState::Succeeded,
                            ) {
                                machine.fail(e);
                                continue;
                            }
                            machine.emit(MachineEvent::Succeeded {
                                email: String::new(),
                                used_two_factor: false,
                                credentials_json: json,
                            });
                        }
                        Err(e) => {
                            machine.fail(e);
                        }
                    }
                }
                Some(UiEvent::Cancel) => continue, // stay parked in Idle
                Some(UiEvent::Logout)
                | Some(UiEvent::Credentials { .. })
                | Some(UiEvent::TwoFactorCode { .. }) => {
                    machine.fail(AuthenticationError::InvalidStateTransition(
                        "no login in progress".into(),
                    ));
                }
                None => return, // command channel closed (runtime dropped)
            },

            // ------------------------------------------- NeedsCredentials
            MachineState::NeedsCredentials => match cmd_rx.recv().await {
                Some(UiEvent::Credentials { email, password }) => {
                    let email = email.trim().to_string();
                    if email.is_empty() {
                        machine.fail(AuthenticationError::InvalidStateTransition(
                            "empty email".into(),
                        ));
                        continue;
                    }
                    if let Err(e) = machine.transition(
                        &[MachineState::NeedsCredentials],
                        MachineState::Working,
                    ) {
                        machine.fail(e);
                        continue;
                    }
                    // Keep the credentials in memory for a possible 2FA
                    // retry (never persisted, never logged).
                    machine.stash_credentials(email.clone(), password.clone());

                    // 1) Root macaroon.
                    let root = fetch_root_macaroon(
                        http,
                        &config.store_url,
                        &config.permissions,
                        &config.channels,
                        &config.packages,
                        &config.description,
                    )
                    .await;
                    let root = match root {
                        Ok(r) => r,
                        Err(e) => {
                            machine.clear_pending_credentials();
                            machine.fail(e);
                            continue;
                        }
                    };

                    // 2) Try the discharge WITHOUT an otp.
                    let attempt =
                        discharge_macaroon(http, &config.login_url, &root, &email, &password, None)
                            .await;

                    match attempt {
                        Ok(discharged) => {
                            let succeeded =
                                finish_success(machine, config, &email, &root, &discharged, false);
                            if succeeded {
                                // Park in Succeeded (loop handles Logout).
                            } else {
                                continue; // machine.fail already called
                            }
                        }
                        Err(AuthenticationError::TwoFactorRequired) => {
                            // 3) Pause: ask the UI for a code.
                            if let Err(e) = machine.transition(
                                &[MachineState::Working],
                                MachineState::Needs2FACode,
                            ) {
                                machine.fail(e);
                                continue;
                            }
                            machine.emit(MachineEvent::Needs2FACode);
                            // Loop continues; we now sit in Needs2FACode.
                        }
                        Err(e) => {
                            machine.clear_pending_credentials();
                            machine.fail(e);
                            continue;
                        }
                    }
                }
                Some(UiEvent::Cancel) => {
                    machine.finish_cancelled("user cancelled login".into());
                    machine.set_state(MachineState::Idle);
                    // Stay alive so a fresh login can start on this handle.
                }
                Some(UiEvent::Logout) | Some(UiEvent::StartLogin { .. }) | Some(UiEvent::TwoFactorCode { .. })
                | Some(UiEvent::RestoreCredentials { .. }) => {
                    machine.fail(AuthenticationError::InvalidStateTransition(
                        "unexpected event in NeedsCredentials".into(),
                    ));
                }
                None => {
                    machine.finish_cancelled("ui disconnected".into());
                    machine.set_state(MachineState::Idle);
                    return;
                }
            },

            // ------------------------------------------------ Needs2FACode
            MachineState::Needs2FACode => match cmd_rx.recv().await {
                    Some(UiEvent::TwoFactorCode { code }) => {
                        let code = code.trim().to_string();
                        if code.is_empty() {
                            machine.fail(AuthenticationError::InvalidStateTransition(
                                "empty 2FA code".into(),
                            ));
                            continue;
                        }
                        if let Err(e) = machine.transition(
                            &[MachineState::Needs2FACode],
                            MachineState::Working,
                        ) {
                            machine.fail(e);
                            continue;
                        }
                        let (email, password) = match machine.take_pending_credentials() {
                            Some(v) => v,
                            None => {
                                machine.fail(AuthenticationError::InvalidStateTransition(
                                    "missing pending credentials for 2FA retry".into(),
                                ));
                                continue;
                            }
                        };
                        // Fresh root macaroon, then discharge with the OTP.
                        let root = fetch_root_macaroon(
                            http,
                            &config.store_url,
                            &config.permissions,
                            &config.channels,
                            &config.packages,
                            &config.description,
                        )
                        .await;
                        let root = match root {
                            Ok(r) => r,
                            Err(e) => {
                                machine.fail(e);
                                continue;
                            }
                        };
                        let attempt = discharge_macaroon(
                            http,
                            &config.login_url,
                            &root,
                            &email,
                            &password,
                            Some(&code),
                        )
                        .await;
                        match attempt {
                            Ok(discharged) => {
                                machine.clear_pending_credentials();
                                let succeeded = finish_success(
                                    machine,
                                    config,
                                    &email,
                                    &root,
                                    &discharged,
                                    true,
                                );
                                if !succeeded {
                                    continue;
                                }
                            }
                            // Wrong/expired code: U1 answers 401 with the
                            // twofactor-required shape again — ask for a new
                            // code (bounded by the user, not by us).
                            Err(AuthenticationError::TwoFactorRequired) => {
                                if let Err(e) = machine.transition(
                                    &[MachineState::Working],
                                    MachineState::Needs2FACode,
                                ) {
                                    machine.fail(e);
                                    continue;
                                }
                                machine.emit(MachineEvent::Needs2FACode);
                            }
                            Err(e) => {
                                machine.clear_pending_credentials();
                                machine.fail(e);
                            }
                        }
                    }
                    Some(UiEvent::Cancel) => {
                        machine.clear_pending_credentials();
                        machine.finish_cancelled("user cancelled 2FA".into());
                        machine.set_state(MachineState::Idle);
                        // Stay alive so a fresh login can start on this handle.
                    }
                    Some(UiEvent::Logout) | Some(UiEvent::StartLogin { .. })
                    | Some(UiEvent::Credentials { .. })
                    | Some(UiEvent::RestoreCredentials { .. }) => {
                        machine.fail(AuthenticationError::InvalidStateTransition(
                            "unexpected event in Needs2FACode".into(),
                        ));
                    }
                    None => {
                        machine.clear_pending_credentials();
                        machine.finish_cancelled("ui disconnected".into());
                        machine.set_state(MachineState::Idle);
                        return;
                    }
                }

            // -------------------------------------------------- Succeeded
            MachineState::Succeeded => match cmd_rx.recv().await {
                Some(UiEvent::Logout) => {
                    let _ = config
                        .store
                        .delete(&config.storage_key)
                        .map_err(|e| AuthenticationError::Storage(e.to_string()));
                    if let Err(e) = machine.transition(&[MachineState::Succeeded], MachineState::Idle)
                    {
                        machine.fail(e);
                        continue;
                    }
                    machine.emit(MachineEvent::LoggedOut);
                }
                Some(UiEvent::Cancel) => {
                    machine.finish_cancelled("cancelled after login".into());
                    machine.set_state(MachineState::Idle);
                    return;
                }
                // Re-import (e.g. `snapcraft export-login` credentials)
                // replaces the current session.
                Some(UiEvent::RestoreCredentials { json }) => {
                    let outcome: Result<()> = (|| {
                        let creds: Credentials = serde_json::from_str(&json)
                            .map_err(|e| AuthenticationError::Storage(format!("bad credentials JSON: {e}")))?;
                        build_macaroon_header(&creds)?;
                        config
                            .store
                            .save(&config.storage_key, &creds)
                            .map_err(|e| AuthenticationError::Storage(e.to_string()))?;
                        Ok(())
                    })();
                    match outcome {
                        Ok(()) => {
                            machine.emit(MachineEvent::Succeeded {
                                email: String::new(),
                                used_two_factor: false,
                                credentials_json: json,
                            });
                        }
                        Err(e) => {
                            machine.fail(e);
                        }
                    }
                }
                Some(UiEvent::StartLogin { .. })
                | Some(UiEvent::Credentials { .. })
                | Some(UiEvent::TwoFactorCode { .. }) => {
                    machine.fail(AuthenticationError::InvalidStateTransition(
                        "already logged in; call logout() first".into(),
                    ));
                    continue;
                }
                // Stay alive in `Succeeded` so a later `Logout` ->
                // `StartLogin` re-login works on the same runtime handle
                // (the command channel must not be dropped).
                None => continue,
            },

            // ---------------------------------- transient / terminal states
            MachineState::Working => {
                // Transient: only set immediately before an await inside the
                // Needs* branches. Waking up here means the channel closed.
                machine.finish_cancelled("driver lost mid-request".into());
                machine.set_state(MachineState::Idle);
                return;
            }
            MachineState::Cancelled => {
                machine.set_state(MachineState::Idle);
                continue;
            }
        }
    }
}

/// Persist credentials and emit `Succeeded`. Returns `true` on success.
fn finish_success(
    machine: &AuthStateMachine,
    config: &AuthConfig,
    email: &str,
    root: &Macaroon,
    discharged: &Macaroon,
    used_two_factor: bool,
) -> bool {
    // Serialize the pair exactly as `craft-store` stores it (v1 binary).
    let root_ser = root.serialize_v1_binary();
    let discharge_ser = discharged.serialize_v1_binary();
    let root_ser = match root_ser {
        Some(s) => s,
        None => {
            machine.fail(AuthenticationError::MacaroonParse(
                "root macaroon is not serializable v1 binary".into(),
            ));
            return false;
        }
    };
    let discharge_ser = match discharge_ser {
        Some(s) => s,
        None => {
            machine.fail(AuthenticationError::MacaroonParse(
                "discharge macaroon is not serializable v1 binary".into(),
            ));
            return false;
        }
    };
    let creds = Credentials {
        root: root_ser,
        discharge: discharge_ser,
    };
    // Round-trip check: the stored pair must bind successfully.
    if build_macaroon_header(&creds).is_err() {
        machine.fail(AuthenticationError::MacaroonParse(
            "persisted macaroon pair failed bind validation".into(),
        ));
        return false;
    }
    if let Err(e) = config
        .store
        .save(&config.storage_key, &creds)
        .map_err(|e| AuthenticationError::Storage(e.to_string()))
    {
        machine.fail(e);
        return false;
    }
    // Wipe the stashed password now that the session is established
    // (covers the non-2FA success path; the 2FA success path already clears).
    machine.clear_pending_credentials();
    let creds_json = match serde_json::to_string(&creds) {
        Ok(j) => j,
        Err(e) => {
            machine.fail(AuthenticationError::Storage(format!("serialize: {e}")));
            return false;
        }
    };
    if let Err(e) = machine.transition(&[MachineState::Working], MachineState::Succeeded) {
        machine.fail(e);
        return false;
    }
    machine.emit(MachineEvent::Succeeded {
        email: email.to_string(),
        used_two_factor,
        credentials_json: creds_json,
    });
    true
}

// ---------------------------------------------------------------------------
// Protocol implementation (pure async functions, unit-testable)
// ---------------------------------------------------------------------------

/// Fetch the store-issued root macaroon from `POST {store}/dev/api/acl/`.
pub async fn fetch_root_macaroon(
    http: &reqwest::Client,
    store_url: &str,
    permissions: &[String],
    channels: &Option<Vec<String>>,
    packages: &Option<Vec<serde_json::Value>>,
    description: &str,
) -> Result<Macaroon> {
    // The current Snap Store login protocol issues the root macaroon from
    // `POST {store}/dev/api/acl/` (the `U1_SNAP_STORE` endpoint set used by
    // snapcraft / craft-store). The older `POST {store}/v1/tokens/usso`
    // path is gone from the store host (it 404s), so do NOT use it.
    let url = format!("{}/dev/api/acl/", store_url.trim_end_matches('/'));
    let mut body = serde_json::json!({
        "permissions": permissions,
        "description": description,
    });
    if let Some(ch) = channels {
        body["channels"] = serde_json::json!(ch);
    }
    if let Some(pk) = packages {
        body["packages"] = serde_json::json!(pk);
    }

    let resp = http.post(&url).json(&body).send().await?;
    let status = resp.status();
    if !status.is_success() {
        let text = resp.text().await.unwrap_or_default();
        let (msg, code) = parse_error_body(&text, status.as_u16());
        return Err(AuthenticationError::Http {
            status: status.as_u16(),
            message: format!("macaroon request failed (code: {code}): {msg}"),
        });
    }
    let v: serde_json::Value = resp.json().await.map_err(|e| {
        AuthenticationError::InvalidResponse(format!("macaroon response is not JSON: {e}"))
    })?;
    let macaroon_str = v
        .get("macaroon")
        .and_then(|m| m.as_str())
        .ok_or_else(|| {
            AuthenticationError::InvalidResponse(
                "missing 'macaroon' field in /dev/api/acl/ response".into(),
            )
        })?;
    Macaroon::parse(macaroon_str)
}

/// Discharge the root macaroon at Ubuntu One.
///
/// Returns `Ok(discharged)` on success and
/// `Err(AuthenticationError::TwoFactorRequired)` when the account requires
/// an OTP (so the state machine can pause for UI input).
pub async fn discharge_macaroon(
    http: &reqwest::Client,
    login_url: &str,
    root: &Macaroon,
    email: &str,
    password: &str,
    otp: Option<&str>,
) -> Result<Macaroon> {
    // Match the caveat to the SSO host derived from the configured login URL
    // (mirrors craft-store's `_get_login_caveat`).
    let host = host_of(login_url);
    let caveat = root.find_discharge_caveat(&host)?;
    let url = format!("{}/api/v2/tokens/discharge", login_url.trim_end_matches('/'));
    let mut body = serde_json::json!({
        "email": email,
        "password": password,
        "caveat_id": caveat.id,
    });
    if let Some(code) = otp {
        if !code.is_empty() {
            body["otp"] = serde_json::json!(code);
        }
    }

    let resp = http.post(&url).json(&body).send().await?;
    let status = resp.status();
    if status.is_success() {
        let v: serde_json::Value = resp.json().await.map_err(|e| {
            AuthenticationError::InvalidResponse(format!("discharge response is not JSON: {e}"))
        })?;
        let disch_str = v
            .get("discharge_macaroon")
            .and_then(|m| m.as_str())
            .ok_or_else(|| {
                AuthenticationError::InvalidResponse(
                    "missing 'discharge_macaroon' field in discharge response".into(),
                )
            })?;
        return Macaroon::parse(disch_str);
    }

    let text = resp.text().await.unwrap_or_default();
    if is_otp_required(&text) {
        return Err(AuthenticationError::TwoFactorRequired);
    }
    let (msg, code) = parse_error_body(&text, status.as_u16());
    match status.as_u16() {
        400 | 401 => Err(AuthenticationError::CredentialsRejected(format!(
            "{msg} (code: {code})"
        ))),
        other => Err(AuthenticationError::Http {
            status: other,
            message: msg,
        }),
    }
}

/// Detect the Ubuntu One "2FA required" error shape.
///
/// Real server / `craft-store` test fixture:
/// ```json
/// {
///   "code": "TWOFACTOR_REQUIRED",
///   "message": "OTP required",
///   "error_list": [{"code": "twofactor-required", "message": "OTP required"}]
/// }
/// ```
pub fn is_otp_required(body: &str) -> bool {
    let v: serde_json::Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => return false,
    };
    if let Some(list) = v
        .get("error_list")
        .or_else(|| v.get("error-list"))
        .and_then(|l| l.as_array())
    {
        for e in list {
            let code = e.get("code").and_then(|c| c.as_str()).unwrap_or("");
            let msg = e.get("message").and_then(|c| c.as_str()).unwrap_or("");
            if code.to_lowercase().contains("twofactor")
                || msg.to_lowercase().contains("otp required")
            {
                return true;
            }
        }
    }
    let code = v.get("code").and_then(|c| c.as_str()).unwrap_or("").to_lowercase();
    let msg = v.get("message").and_then(|c| c.as_str()).unwrap_or("").to_lowercase();
    code.contains("twofactor") || msg.contains("otp required")
}

/// Extract `(message, code)` from an error body (best effort, no panics).
pub fn parse_error_body(body: &str, status: u16) -> (String, String) {
    let v: serde_json::Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => {
            let cut = body
                .char_indices()
                .take_while(|(i, _)| *i < 200)
                .last()
                .map(|(i, c)| i + c.len_utf8())
                .unwrap_or(0);
            return (
                format!("HTTP {}: {}", status, &body[..cut]),
                String::new(),
            );
        }
    };
    let code = v
        .get("code")
        .and_then(|c| c.as_str())
        .map(String::from)
        .unwrap_or_default();
    let message = v
        .get("message")
        .and_then(|m| m.as_str())
        .map(String::from)
        .or_else(|| {
            v.get("error_list")
                .and_then(|l| l.as_array())
                .and_then(|l| l.first())
                .and_then(|e| e.get("message"))
                .and_then(|m| m.as_str())
                .map(String::from)
        })
        .unwrap_or_else(|| format!("HTTP {status}"));
    (message, code)
}

/// Parse a `whoami` response into an [`AccountInfo`].
///
/// Accepts the standard shape (`account` object) *and* a flat/legacy shape
/// (top-level `email`/`username`/`id`), so on-prem store variants keep
/// working.
pub fn parse_account_info(v: &serde_json::Value) -> Result<AccountInfo> {
    // `account.*` fields live in the nested object; `permissions` /
    // `channels` / `expires` are top-level. For flat/legacy responses
    // (no `account` object) both point at the same value.
    let account = v.get("account").cloned().unwrap_or_else(|| v.clone());
    let s = |obj: &serde_json::Value, k: &str| {
        obj.get(k)
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string()
    };
    let strs = |obj: &serde_json::Value, k: &str| match obj.get(k) {
        Some(serde_json::Value::Array(list)) => list
            .iter()
            .filter_map(|x| x.as_str().map(String::from))
            .collect(),
        _ => Vec::new(),
    };
    Ok(AccountInfo {
        id: s(&account, "id"),
        email: s(&account, "email"),
        username: s(&account, "username"),
        display_name: s(&account, "display-name"),
        permissions: strs(v, "permissions"),
        channels: strs(v, "channels"),
        expires: s(v, "expires"),
    })
}

/// Build the `Authorization` header value for store API calls:
/// `Macaroon root={root}, discharge={bound}` where the discharge is bound
/// to the root's signature.
pub fn build_macaroon_header(creds: &Credentials) -> Result<String> {
    let root = Macaroon::parse(&creds.root)?;
    let discharge = Macaroon::parse(&creds.discharge)?;
    let bound_sig = root.bind_discharge_signature(&discharge)?;
    let bound = discharge
        .rebind_signature(&bound_sig)
        .ok_or_else(|| {
            AuthenticationError::MacaroonParse(
                "discharge macaroon cannot be re-serialized with bound signature".into(),
            )
        })?;
    let bound_ser = bound.serialize_v1_binary().ok_or_else(|| {
        AuthenticationError::MacaroonParse(
            "bound discharge macaroon is not v1-serializable".into(),
        )
    })?;
    Ok(format!(
        "Macaroon root={}, discharge={bound_ser}",
        creds.root
    ))
}

/// Host (netloc) of a URL, for caveat matching.
pub fn host_of(url: &str) -> String {
    let rest = url.split_once("://").map(|(_, r)| r).unwrap_or(url);
    rest.split('/').next().unwrap_or(rest).trim_end_matches('/').to_string()
}

/// True when the host is a loopback address (127.0.0.0/8, ::1, or "localhost").
fn is_loopback_host(host: &str) -> bool {
    let h = host.to_lowercase();
    if h == "localhost" || h == "::1" || h == "[::1]" {
        return true;
    }
    if h.starts_with("127.") {
        // 127.x.y.z
        return true;
    }
    false
}

/// Split a URL into (scheme, host) without a full URL parser.
/// Returns None when the input is not a recognizable URL.
fn parse_scheme_host(url: &str) -> Option<(&str, &str)> {
    let (scheme, rest) = url.split_once("://")?;
    let host = rest.split('/').next()?.trim_end_matches('/');
    if host.is_empty() {
        return None;
    }
    Some((scheme, host))
}

/// Validate that the store and login endpoints are trusted.
///
/// Called from the FFI boundary (auth_runtime_init) to stop a configuration
/// bug or a hostile Dart caller from redirecting the user password to an
/// untrusted host.
///
/// Accepted:
///  * `https` on hosts under *.snapcraft.io or *.ubuntu.com (the production
///    Snap Store / Ubuntu One domains), or
///  * `http` on loopback (127.0.0.0/8, ::1, localhost) - the local
///    mock-store test harness used by the Dart/Rust integration tests.
///
/// Everything else is rejected.
pub fn assert_trusted_endpoints(store_url: &str, login_url: &str) -> Result<()> {
    for (label, url) in [("store_url", store_url), ("login_url", login_url)] {
        let (scheme, host) = parse_scheme_host(url).ok_or_else(|| {
            AuthenticationError::InvalidResponse(format!(
                "{label}: cannot parse scheme/host from '{url}'"
            ))
        })?;
        match scheme {
            "https" => {
                let h = host.to_lowercase();
                let trusted = ["snapcraft.io", "ubuntu.com"].iter().any(|d| {
                    h == *d || h.ends_with(&format!(".{d}"))
                });
                if !trusted {
                    return Err(AuthenticationError::InvalidResponse(format!(
                        "{label}: untrusted host '{host}' (only *.snapcraft.io / *.ubuntu.com allowed)"
                    )));
                }
            }
            "http" => {
                if !is_loopback_host(host) {
                    return Err(AuthenticationError::InvalidResponse(format!(
                        "{label}: http is only allowed on loopback (test harness), got '{host}'"
                    )));
                }
            }
            other => {
                return Err(AuthenticationError::InvalidResponse(format!(
                    "{label}: unsupported scheme '{other}' (only https, or http on loopback)"
                )));
            }
        }
    }
    Ok(())
}



#[cfg(test)]
mod tests {
    use super::parse_account_info;

    #[test]
    fn parses_standard_whoami_shape() {
        let v = serde_json::json!({
            "account": {
                "id": "DEADBEEF",
                "email": "user@example.com",
                "username": "user",
                "display-name": "User Name"
            },
            "permissions": ["package_access", "package_push"],
            "channels": null,
            "expires": "2026-10-15T12:00:00+00:00"
        });
        let a = parse_account_info(&v).expect("parse");
        assert_eq!(a.id, "DEADBEEF");
        assert_eq!(a.email, "user@example.com");
        assert_eq!(a.username, "user");
        assert_eq!(a.display_name, "User Name");
        assert_eq!(a.permissions, vec!["package_access", "package_push"]);
        assert!(a.channels.is_empty());
        assert_eq!(a.expires, "2026-10-15T12:00:00+00:00");
    }

    #[test]
    fn parses_flat_legacy_shape() {
        let v = serde_json::json!({
            "id": "ABC123",
            "email": "a@b.c",
            "username": "ab",
            "permissions": []
        });
        let a = parse_account_info(&v).expect("parse");
        assert_eq!(a.id, "ABC123");
        assert_eq!(a.email, "a@b.c");
        assert_eq!(a.username, "ab");
    }
}
