//! Library form of the WhatIsIt Rust engine.
//!
//! The HTTP binary (`src/main.rs`) and the HarmonyOS NAPI cdylib
//! (`../engine`) share these modules, so the protocol/state/API behaviour has
//! one implementation.

pub mod calls;
pub mod events;
pub mod history;
pub mod media;
pub mod state;
pub mod store;
pub mod web;
