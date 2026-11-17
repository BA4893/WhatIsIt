//! Shared state: config, the in-memory history store, and the event broadcast
//! channel that the WebSocket server subscribes to.

use anyhow::Result;
use std::sync::Arc;
use tokio::sync::broadcast;

use crate::events::Config;
use crate::store::HistoryStore;

/// What the app sends back to resolve a pending passkey (WebAuthn) request.
#[derive(Debug)]
pub enum PasskeyAnswer {
    /// The WebAuthn assertion, ready for the `<passkey_prologue>` IQ.
    Assertion(whatsapp_rust::passkey::Assertion),
    /// The user cancelled the passkey ceremony.
    Cancelled,
}

/// Outbound events pushed to app WebSocket clients.
#[derive(Clone, Debug, serde::Serialize)]
pub enum Event {
    #[serde(rename = "qr")]
    Qr { qr: String },
    #[serde(rename = "linked")]
    Linked { phone: String },
    #[serde(rename = "message")]
    Message { chat: String },
    #[serde(rename = "receipt")]
    Receipt { chat: String },
    #[serde(rename = "chats")]
    Chats,
    #[serde(rename = "logged_out")]
    LoggedOut,
    #[serde(rename = "incoming_call")]
    IncomingCall { call_id: String, from: String, video: bool },
    #[serde(rename = "call_state")]
    CallState { call_id: String, state: String },
    #[serde(rename = "pair_code")]
    PairCode { code: String },
    /// WhatsApp's SHORTCAKE passkey gate wants a WebAuthn assertion. The app
    /// must run `navigator.credentials.get`-style flow and POST it back.
    #[serde(rename = "passkey_request")]
    PasskeyRequest { options: String },
    /// A verification code to show on the phone (fresh-link confirmation).
    #[serde(rename = "passkey_confirmation")]
    PasskeyConfirmation { code: String },
    #[serde(rename = "passkey_error")]
    PasskeyError { error: String },
}

/// One call-history row served by `/calls`.
#[derive(Clone, Debug, serde::Serialize)]
pub struct CallLogEntry {
    pub id: String,
    pub peer: String,
    pub dir: String,
    pub video: bool,
    pub missed: bool,
    pub time: i64,
    pub name: String,
}

/// The server's mutable state, shared across the bot callbacks and HTTP handlers.
#[derive(Clone)]
pub struct AppState {
    pub cfg: Arc<Config>,
    pub store: Arc<HistoryStore>,
    /// Broadcast channel for WS events. Subscribers receive every event.
    pub tx: broadcast::Sender<Event>,
    /// Current QR code (while pairing) — read by `/status`.
    pub current_qr: Arc<std::sync::Mutex<String>>,
    /// Phone number once linked.
    pub phone: Arc<std::sync::Mutex<String>>,
    /// Active WhatsApp calls (media relay handles).
    pub calls: crate::calls::CallRegistry,
    /// The 8-char pair code issued by the phone-number flow ("" when none).
    pub pair_code: Arc<std::sync::Mutex<String>>,
    /// Last passkey request options JSON (so the app can recover if it missed
    /// the WS event).
    pub passkey_pending: Arc<std::sync::Mutex<Option<String>>>,
    /// Resolves a pending passkey ceremony with the app's assertion (or cancel).
    /// `None` when no passkey ceremony is waiting.
    pub passkey_answer: Arc<std::sync::Mutex<Option<tokio::sync::oneshot::Sender<PasskeyAnswer>>>>,
    /// Recent call rows for the app's Calls tab.
    pub call_log: Arc<std::sync::Mutex<Vec<CallLogEntry>>>,
}

impl AppState {
    pub async fn new(cfg: Arc<Config>) -> Result<Self> {
        let store = HistoryStore::new(cfg.clone()).await?;
        let (tx, _rx) = broadcast::channel(256);
        Ok(Self {
            cfg,
            store: Arc::new(store),
            tx,
            current_qr: Arc::new(std::sync::Mutex::new(String::new())),
            phone: Arc::new(std::sync::Mutex::new(String::new())),
            calls: crate::calls::CallRegistry::default(),
            pair_code: Arc::new(std::sync::Mutex::new(String::new())),
            passkey_pending: Arc::new(std::sync::Mutex::new(None)),
            passkey_answer: Arc::new(std::sync::Mutex::new(None)),
            call_log: Arc::new(std::sync::Mutex::new(Vec::new())),
        })
    }

    /// Append a call row; keeps the newest 200.
    pub fn add_call(&self, entry: CallLogEntry) {
        if let Ok(mut log) = self.call_log.lock() {
            log.insert(0, entry);
            log.truncate(200);
        }
    }

    /// Newest-first call history for `/calls`.
    pub fn calls(&self) -> Vec<CallLogEntry> {
        self.call_log
            .lock()
            .map(|log| log.clone())
            .unwrap_or_default()
    }

    pub fn is_linked(&self) -> bool {
        !self.phone.lock().unwrap().is_empty()
    }

    pub fn phone(&self) -> String {
        self.phone.lock().unwrap().clone()
    }

    pub fn set_qr(&self, qr: &str) {
        *self.current_qr.lock().unwrap() = qr.to_string();
    }

    pub fn set_phone(&self, phone: &str) {
        *self.phone.lock().unwrap() = phone.to_string();
    }

    /// Record a new passkey request so `/passkey/request` can serve it.
    pub fn set_passkey_pending(&self, options: String) {
        *self.passkey_pending.lock().unwrap() = Some(options);
    }

    pub fn take_passkey_pending(&self) -> Option<String> {
        self.passkey_pending.lock().unwrap().take()
    }

    /// Install the oneshot the app's `/passkey/assertion` resolves. Replaces
    /// (and cancels) any prior pending ceremony.
    pub fn set_passkey_answer(
        &self,
        tx: tokio::sync::oneshot::Sender<PasskeyAnswer>,
    ) {
        let mut slot = self.passkey_answer.lock().unwrap();
        if let Some(old) = slot.take() {
            let _ = old.send(PasskeyAnswer::Cancelled);
        }
        *slot = Some(tx);
    }

    /// Take the oneshot (so the app's answer resolves the *current* ceremony).
    pub fn take_passkey_answer(
        &self,
    ) -> Option<tokio::sync::oneshot::Sender<PasskeyAnswer>> {
        self.passkey_answer.lock().unwrap().take()
    }
}
