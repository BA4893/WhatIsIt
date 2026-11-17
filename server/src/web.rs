//! HTTP + WebSocket API for the app.

use axum::{
    extract::{ws::WebSocketUpgrade, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use std::sync::Arc;
use whatsapp_rust::prelude::*;

use crate::state::{AppState, CallLogEntry, Event};

/// Build the axum router.
pub fn router(state: AppState, client: Arc<whatsapp_rust::Client>) -> Router {
    Router::new()
        .route("/status", get(status))
        .route("/pair", post(pair))
        .route("/pair-code", post(pair_code))
        .route("/chats", get(chats))
        .route("/messages", get(messages))
        .route("/send", post(send))
        .route("/send-media", post(send_media))
        .route("/read", post(read))
        .route("/react", post(react))
        .route("/logout", post(logout))
        .route("/media/{id}/{kind}", get(media))
        .route("/calls", get(call_history))
        .route("/call", post(call_start))
        .route("/call/accept", post(call_accept))
        .route("/call/reject", post(call_reject))
        .route("/call/end", post(call_end))
        .route("/call/mute", post(call_mute))
        .route("/call/camera", post(call_camera))
        .route("/call/state", get(call_state))
        .route("/passkey/request", get(passkey_request))
        .route("/passkey/assertion", post(passkey_assertion))
        .route("/passkey/confirm", post(passkey_confirm))
        .route("/passkey/cancel", post(passkey_cancel))
        .route("/ws", get(ws))
        .with_state(ApiState { state, client })
}

#[derive(Clone)]
pub(crate) struct ApiState {
    pub state: AppState,
    pub client: Arc<whatsapp_rust::Client>,
}

/// Auth middleware: require Bearer token or ?token= when WHATSAPP_TOKEN is set.
fn authorized(headers: &HeaderMap, uri: &axum::http::Uri, cfg: &crate::events::Config) -> bool {
    if cfg.token.is_empty() {
        return true;
    }
    if let Some(auth) = headers.get(header::AUTHORIZATION) {
        if let Ok(v) = auth.to_str() {
            if v == format!("Bearer {}", cfg.token) {
                return true;
            }
        }
    }
    if let Some(q) = uri.query() {
        for pair in q.split('&') {
            if let Some((k, v)) = pair.split_once('=') {
                if k == "token" && v == cfg.token {
                    return true;
                }
            }
        }
    }
    false
}

fn reject() -> Response {
    (StatusCode::UNAUTHORIZED, Json(serde_json::json!({ "error": "unauthorized" }))).into_response()
}

// ---- handlers ----

async fn status(State(api): State<ApiState>, headers: HeaderMap, uri: axum::http::Uri) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    let qr = api.state.current_qr.lock().unwrap().clone();
    let phone = api.state.phone();
    let linked = api.state.is_linked();
    Json(serde_json::json!({ "linked": linked, "phone": phone, "qr": qr })).into_response()
}

async fn pair(State(api): State<ApiState>, headers: HeaderMap, uri: axum::http::Uri) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    if api.state.is_linked() {
        return Json(serde_json::json!({ "ok": true })).into_response();
    }
    // whatsapp-rust starts pairing automatically when not logged in; nothing
    // to do server-side beyond confirming we're awaiting a QR.
    Json(serde_json::json!({ "ok": true })).into_response()
}

#[derive(Deserialize)]
struct PairCodeReq {
    #[serde(default)]
    country: String,
    #[serde(default)]
    phone: String,
}

/// Phone-number linking: issue an 8-char pairing code ("Link with phone
/// number instead"). Body: { "country": "1", "phone": "5551234567" }.
async fn pair_code(State(api): State<ApiState>, headers: HeaderMap, uri: axum::http::Uri, Json(body): Json<PairCodeReq>) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    if api.state.is_linked() {
        return Json(serde_json::json!({ "ok": true })).into_response();
    }
    let digits = |s: &str| -> String { s.chars().filter(|c| c.is_ascii_digit()).collect() };
    let country = digits(&body.country);
    let phone = digits(&body.phone);
    if country.is_empty() || phone.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(serde_json::json!({ "error": "country and phone required" }))).into_response();
    }
    let options = whatsapp_rust::pair_code::PairCodeOptions {
        phone_number: format!("{country}{phone}"),
        show_push_notification: true,
        ..Default::default()
    };
    match api.client.pair_with_code(options).await {
        Ok(code) => {
            // Store the code so /status can surface it, and broadcast it.
            *api.state.pair_code.lock().unwrap() = code.clone();
            let _ = api.state.tx.send(Event::PairCode { code: code.clone() });
            Json(serde_json::json!({ "ok": true, "code": code })).into_response()
        }
        Err(e) => {
            log::warn!("pair-code failed: {e:?}");
            (StatusCode::BAD_REQUEST, Json(serde_json::json!({ "error": "pair-code failed" }))).into_response()
        }
    }
}

async fn chats(State(api): State<ApiState>, headers: HeaderMap, uri: axum::http::Uri) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    if !api.state.is_linked() {
        return (StatusCode::FORBIDDEN, Json(serde_json::json!({ "error": "not linked" }))).into_response();
    }
    Json(serde_json::json!({ "chats": api.state.store.chats() })).into_response()
}

async fn messages(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    axum::extract::Query(params): axum::extract::Query<MessagesParams>,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    if !api.state.is_linked() {
        return (StatusCode::FORBIDDEN, Json(serde_json::json!({ "error": "not linked" }))).into_response();
    }
    let chat = params.chat.unwrap_or_default();
    if chat.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(serde_json::json!({ "error": "chat required" }))).into_response();
    }
    let msgs = api.state.store.messages(&chat, 200);
    Json(serde_json::json!({ "messages": msgs })).into_response()
}

#[derive(Deserialize)]
struct MessagesParams {
    chat: Option<String>,
}

#[derive(Deserialize)]
struct SendBody {
    chat: String,
    text: String,
    #[serde(default)]
    reply_to: Option<String>,
}

async fn send(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    Json(body): Json<SendBody>,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    if !api.state.is_linked() {
        return (StatusCode::FORBIDDEN, Json(serde_json::json!({ "error": "not linked" }))).into_response();
    }
    if body.chat.is_empty() || body.text.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(serde_json::json!({ "error": "chat and text required" }))).into_response();
    }
    let jid: Jid = match body.chat.parse() {
        Ok(j) => j,
        Err(e) => return (StatusCode::BAD_REQUEST, Json(serde_json::json!({ "error": format!("bad jid: {e}") }))).into_response(),
    };
    let msg = wa::Message::text(&body.text);
    match api.client.send_message(jid, msg).await {
        Ok(sent) => Json(serde_json::json!({ "ok": true, "id": sent.message_id })).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e.to_string() }))).into_response(),
    }
}

async fn send_media(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    mut multipart: axum::extract::Multipart,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    if !api.state.is_linked() {
        return (StatusCode::FORBIDDEN, Json(serde_json::json!({ "error": "not linked" }))).into_response();
    }
    match crate::media::handle_send_media(&api, &mut multipart).await {
        Ok(id) => Json(serde_json::json!({ "ok": true, "id": id })).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, Json(serde_json::json!({ "error": e.to_string() }))).into_response(),
    }
}

#[derive(Deserialize)]
struct ChatBody {
    chat: String,
}

async fn read(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    Json(body): Json<ChatBody>,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    if !api.state.is_linked() {
        return (StatusCode::FORBIDDEN, Json(serde_json::json!({ "error": "not linked" }))).into_response();
    }
    let jid: Jid = match body.chat.parse() {
        Ok(j) => j,
        Err(e) => return (StatusCode::BAD_REQUEST, Json(serde_json::json!({ "error": format!("bad jid: {e}") }))).into_response(),
    };
    let ids: Vec<String> = api
        .state
        .store
        .messages(&body.chat, 50)
        .into_iter()
        .filter(|m| !m.from_me)
        .map(|m| m.id)
        .collect();
    if !ids.is_empty() {
        let id_refs: Vec<&str> = ids.iter().map(|s| s.as_str()).collect();
        if let Err(e) = api.client.mark_as_read(&jid, None, &id_refs).await {
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e.to_string() }))).into_response();
        }
    }
    api.state.store.mark_read(&body.chat);
    Json(serde_json::json!({ "ok": true })).into_response()
}

#[derive(Deserialize)]
struct ReactBody {
    chat: String,
    #[serde(rename = "messageId")]
    message_id: String,
    emoji: String,
}

async fn react(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    Json(body): Json<ReactBody>,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    if !api.state.is_linked() {
        return (StatusCode::FORBIDDEN, Json(serde_json::json!({ "error": "not linked" }))).into_response();
    }
    let jid: Jid = match body.chat.parse() {
        Ok(j) => j,
        Err(e) => return (StatusCode::BAD_REQUEST, Json(serde_json::json!({ "error": format!("bad jid: {e}") }))).into_response(),
    };
    match crate::media::send_reaction(&api, jid, &body.message_id, &body.emoji).await {
        Ok(()) => {
            api.state.store.add_reaction(&body.chat, &body.message_id, &body.emoji);
            Json(serde_json::json!({ "ok": true })).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e.to_string() }))).into_response(),
    }
}

async fn logout(State(api): State<ApiState>, headers: HeaderMap, uri: axum::http::Uri) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    api.client.logout().await;
    api.state.set_phone("");
    api.state.store.set_phone("");
    let _ = api.state.tx.send(Event::LoggedOut);
    Json(serde_json::json!({ "ok": true })).into_response()
}

async fn media(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    axum::extract::Path((id, kind)): axum::extract::Path<(String, String)>,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    crate::media::serve_media(&api, &id, &kind).await
}

/// WebSocket: on connect, send the current status, then stream events.
async fn ws(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    ws: WebSocketUpgrade,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    let state = api.state.clone();
    ws.on_upgrade(move |socket| handle_ws(socket, state))
}

// ---- call handlers ----

#[derive(Deserialize)]
struct CallStartBody {
    chat: String,
    #[serde(default)]
    video: bool,
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

async fn call_history(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    Json(serde_json::json!({ "calls": api.state.calls() })).into_response()
}

async fn call_start(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    Json(body): Json<CallStartBody>,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    if !api.state.is_linked() {
        return (StatusCode::FORBIDDEN, Json(serde_json::json!({ "error": "not linked" }))).into_response();
    }
    match crate::calls::start_call(&api.client, &api.state.calls, &body.chat, body.video).await {
        Ok(call_id) => {
            let name = api.state.store.name_for(&body.chat);
            api.state.add_call(CallLogEntry {
                id: call_id.clone(),
                peer: body.chat.clone(),
                dir: "out".into(),
                video: body.video,
                missed: false,
                time: now_ms(),
                name,
            });
            Json(serde_json::json!({ "ok": true, "callId": call_id })).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e.to_string() }))).into_response(),
    }
}

#[derive(Deserialize)]
struct CallIdBody {
    #[serde(rename = "callId")]
    call_id: String,
    #[serde(default)]
    video: bool,
}

async fn call_accept(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    Json(body): Json<CallIdBody>,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    let Some(pending) = api.state.calls.take_pending(&body.call_id) else {
        return (StatusCode::NOT_FOUND, Json(serde_json::json!({ "error": "no such incoming call" }))).into_response();
    };
    let Some(incoming) = pending.incoming else {
        return (StatusCode::NOT_FOUND, Json(serde_json::json!({ "error": "incoming call expired" }))).into_response();
    };
    match crate::calls::accept_call(&api.client, &api.state.calls, &incoming, body.video).await {
        Ok(call_id) => {
            let peer = pending.from.clone();
            let name = api.state.store.name_for(&peer);
            api.state.add_call(CallLogEntry {
                id: call_id.clone(),
                peer,
                dir: "in".into(),
                video: body.video,
                missed: false,
                time: now_ms(),
                name,
            });
            Json(serde_json::json!({ "ok": true, "callId": call_id })).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e.to_string() }))).into_response(),
    }
}

async fn call_reject(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    Json(body): Json<CallIdBody>,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    let Some(pending) = api.state.calls.take_pending(&body.call_id) else {
        return (StatusCode::NOT_FOUND, Json(serde_json::json!({ "error": "no such incoming call" }))).into_response();
    };
    let peer = pending.from.clone();
    let video = pending.video;
    if let Some(incoming) = pending.incoming {
        if let Err(e) = crate::calls::reject_call(&api.client, &incoming).await {
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e.to_string() }))).into_response();
        }
    }
    let name = api.state.store.name_for(&peer);
    api.state.add_call(CallLogEntry {
        id: body.call_id.clone(),
        peer,
        dir: "in".into(),
        video,
        missed: true,
        time: now_ms(),
        name,
    });
    Json(serde_json::json!({ "ok": true })).into_response()
}

async fn call_end(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    Json(body): Json<CallIdBody>,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    if let Err(e) = crate::calls::hangup(&api.state.calls, &body.call_id).await {
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e.to_string() }))).into_response();
    }
    Json(serde_json::json!({ "ok": true })).into_response()
}

#[derive(Deserialize)]
struct CallMuteBody {
    #[serde(rename = "callId")]
    call_id: String,
    muted: bool,
}

async fn call_mute(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    Json(body): Json<CallMuteBody>,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    if let Err(e) = crate::calls::set_muted(&api.state.calls, &body.call_id, body.muted).await {
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(serde_json::json!({ "error": e.to_string() }))).into_response();
    }
    Json(serde_json::json!({ "ok": true })).into_response()
}

#[derive(Deserialize)]
struct CallCameraBody {
    #[serde(rename = "callId")]
    call_id: String,
    on: bool,
}

async fn call_camera(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    Json(body): Json<CallCameraBody>,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    log::info!("call {} camera={}", body.call_id, body.on);
    Json(serde_json::json!({ "ok": true })).into_response()
}

async fn call_state(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    let calls: Vec<serde_json::Value> = api
        .state
        .calls
        .list()
        .into_iter()
        .map(|(call_id, peer, video)| serde_json::json!({ "callId": call_id, "peer": peer, "video": video }))
        .collect();
    Json(serde_json::json!({ "calls": calls, "active": calls.len() })).into_response()
}

// ---- passkey (SHORTCAKE) handlers ----

/// Return the pending passkey request options (the app's WebAuthn
/// `PublicKeyCredentialRequestOptions` JSON), if any. The app normally gets
/// this over the WS `passkey_request` event; this lets it recover if it missed
/// the event or reconnects mid-ceremony.
async fn passkey_request(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    match api.state.take_passkey_pending() {
        Some(options) => Json(serde_json::json!({ "options": options })).into_response(),
        None => (StatusCode::NOT_FOUND, Json(serde_json::json!({ "error": "no pending passkey request" }))).into_response(),
    }
}

#[derive(Deserialize)]
struct PasskeyAssertionBody {
    /// Base64url (no padding) of the credential rawId.
    #[serde(rename = "credentialId")]
    credential_id: String,
    /// Base64url (no padding) of the WebAuthn assertion JSON
    /// ({id, rawId, type, response:{clientDataJSON, authenticatorData, signature, userHandle}}).
    #[serde(rename = "assertionJson")]
    assertion_json: String,
}

/// The app resolved the pending passkey ceremony with a WebAuthn assertion.
async fn passkey_assertion(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
    Json(body): Json<PasskeyAssertionBody>,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    use base64::Engine as _;
    let b64url = base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let credential_id = match b64url.decode(&body.credential_id) {
        Ok(b) => b,
        Err(e) => return (StatusCode::BAD_REQUEST, Json(serde_json::json!({ "error": format!("bad credentialId: {e}") }))).into_response(),
    };
    let assertion_json = match b64url.decode(&body.assertion_json) {
        Ok(b) => b,
        Err(e) => return (StatusCode::BAD_REQUEST, Json(serde_json::json!({ "error": format!("bad assertionJson: {e}") }))).into_response(),
    };
    let tx = match api.state.take_passkey_answer() {
        Some(tx) => tx,
        None => return (StatusCode::CONFLICT, Json(serde_json::json!({ "error": "no pending passkey request" }))).into_response(),
    };
    let assertion = whatsapp_rust::passkey::Assertion {
        assertion_json,
        credential_id,
    };
    if tx.send(crate::state::PasskeyAnswer::Assertion(assertion)).is_err() {
        // The ceremony already timed out / was cancelled on our side.
        return (StatusCode::CONFLICT, Json(serde_json::json!({ "error": "passkey request no longer pending" }))).into_response();
    }
    Json(serde_json::json!({ "ok": true })).into_response()
}

/// The user confirmed the verification code on a fresh link: tell the client
/// to finish the SHORTCAKE handshake.
async fn passkey_confirm(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    match api.client.send_passkey_confirmation().await {
        Ok(()) => Json(serde_json::json!({ "ok": true })).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, Json(serde_json::json!({ "error": e.to_string() }))).into_response(),
    }
}

/// The user cancelled the passkey ceremony; drop any pending request.
async fn passkey_cancel(
    State(api): State<ApiState>,
    headers: HeaderMap,
    uri: axum::http::Uri,
) -> Response {
    if !authorized(&headers, &uri, &api.state.cfg) {
        return reject();
    }
    api.state.take_passkey_pending();
    if let Some(tx) = api.state.take_passkey_answer() {
        let _ = tx.send(crate::state::PasskeyAnswer::Cancelled);
    }
    Json(serde_json::json!({ "ok": true })).into_response()
}

async fn handle_ws(socket: axum::extract::ws::WebSocket, state: AppState) {
    let (sender, mut receiver) = socket.split();
    let sender = std::sync::Arc::new(tokio::sync::Mutex::new(sender));
    let mut rx = state.tx.subscribe();
    // Initial status snapshot.
    let qr = state.current_qr.lock().unwrap().clone();
    let phone = state.phone();
    let init = serde_json::json!({
        "type": "status",
        "linked": state.is_linked(),
        "phone": phone,
        "qr": qr,
    });
    sender
        .lock()
        .await
        .send(axum::extract::ws::Message::Text(init.to_string()))
        .await
        .ok();

    // Media relay: forward peer audio + video to the app over the same WS.
    let calls = state.calls.clone();
    let media_sender = sender.clone();
    tokio::spawn(async move {
        relay_media_out(calls, media_sender).await;
    });

    // Read loop: event stream (from the broadcast) + binary media frames.
    loop {
        tokio::select! {
            evt = rx.recv() => {
                match evt {
                    Ok(evt) => {
                        let payload = match &evt {
                            Event::Qr { qr } => serde_json::json!({ "type": "qr", "qr": qr }),
                            Event::Linked { phone } => serde_json::json!({ "type": "linked", "phone": phone }),
                            Event::Message { chat } => serde_json::json!({ "type": "message", "chat": chat }),
                            Event::Receipt { chat } => serde_json::json!({ "type": "receipt", "chat": chat }),
                            Event::Chats => serde_json::json!({ "type": "chats" }),
                            Event::LoggedOut => serde_json::json!({ "type": "logged_out" }),
                            Event::IncomingCall { call_id, from, video } => serde_json::json!({ "type": "incoming_call", "callId": call_id, "from": from, "video": video }),
                            Event::CallState { call_id, state } => serde_json::json!({ "type": "call_state", "callId": call_id, "state": state }),
                            Event::PairCode { code } => serde_json::json!({ "type": "pair_code", "code": code }),
                            Event::PasskeyRequest { options } => serde_json::json!({ "type": "passkey_request", "options": options }),
                            Event::PasskeyConfirmation { code } => serde_json::json!({ "type": "passkey_confirmation", "code": code }),
                            Event::PasskeyError { error } => serde_json::json!({ "type": "passkey_error", "error": error }),
                        };
                        if sender
                            .lock()
                            .await
                            .send(axum::extract::ws::Message::Text(payload.to_string()))
                            .await
                            .is_err()
                        {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            msg = receiver.next() => {
                match msg {
                    Some(Ok(axum::extract::ws::Message::Binary(bytes))) => {
                        let data = bytes.to_vec();
                        if data.is_empty() { continue; }
                        let tag = data[0];
                        let payload = &data[1..];
                        let list = state.calls.list();
                        if list.is_empty() { continue; }
                        let call_id = list[0].0.clone();
                        if let Some(relay) = state.calls.get(&call_id) {
                            match tag {
                                1 => { // mic PCM s16le → AudioSource
                                    let frames: Vec<i16> = payload
                                        .chunks_exact(2)
                                        .map(|c| i16::from_le_bytes([c[0], c[1]]))
                                        .collect();
                                    let _ = relay.mic_tx.try_send(frames);
                                }
                                2 => { // camera H.264 AU → VideoSource
                                    if let Some(cam) = &relay.cam_tx {
                                        let _ = cam.try_send(payload.to_vec());
                                    }
                                }
                                _ => {}
                            }
                        }
                    }
                    Some(Ok(axum::extract::ws::Message::Close(_))) => break,
                    Some(Err(_)) => break,
                    _ => {}
                }
            }
        }
    }
}

/// Forward whatsapp-rust media (peer audio PCM + peer video AUs) to the app.
///   audio: [1][pcm s16le bytes]
///   video: [2][keyframe:u8][h264 annex-b AU]
async fn relay_media_out(
    calls: crate::calls::CallRegistry,
    tx: std::sync::Arc<tokio::sync::Mutex<futures_util::stream::SplitSink<axum::extract::ws::WebSocket, axum::extract::ws::Message>>>,
) {
    loop {
        let list = calls.list();
        if list.is_empty() {
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            continue;
        }
        let call_id = list[0].0.clone();
        let Some(relay) = calls.get(&call_id) else {
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            continue;
        };
        // Peer audio → app.
        if let Ok(pcm) = relay.peer_audio_rx.try_recv() {
            let mut out = Vec::with_capacity(1 + pcm.len() * 2);
            out.push(1);
            for s in &pcm {
                out.extend_from_slice(&s.to_le_bytes());
            }
            if tx.lock().await.send(axum::extract::ws::Message::Binary(out.into())).await.is_err() {
                return;
            }
        }
        // Peer video → app (Annex-B AU + keyframe flag).
        if let Some(video_rx) = &relay.peer_video_rx {
            if let Ok(frame) = video_rx.try_recv() {
                let mut out = Vec::with_capacity(2 + frame.data.len());
                out.push(2);
                out.push(frame.keyframe as u8);
                out.extend_from_slice(&frame.data);
                if tx.lock().await.send(axum::extract::ws::Message::Binary(out.into())).await.is_err() {
                    return;
                }
            }
        }
        // Yield so audio/video interleave and we don't spin.
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
}
