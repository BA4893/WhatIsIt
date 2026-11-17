//! WhatIsIt server — a whatsapp-rust backend exposing HTTP + WebSocket for the
//! HarmonyOS app: QR pairing, chats, messages, media.

use anyhow::Result;
use std::sync::Arc;

use whatisit_server::events;
use whatisit_server::state::AppState;
use whatisit_server::web;

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let cfg = Arc::new(events::Config::from_env());
    let state = AppState::new(cfg.clone()).await?;

    // Build the WhatsApp bot and spawn it in the background.
    let (_bot_handle, client) = events::build_bot(cfg.clone(), state.clone()).await?;

    // Run the HTTP/WS server on the same runtime.
    let app = web::router(state, client);
    let addr = format!("0.0.0.0:{}", cfg.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    log::info!("WhatIsIt server listening on {addr}");
    axum::serve(listener, app).await?;
    Ok(())
}
