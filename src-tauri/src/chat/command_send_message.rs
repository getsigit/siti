//! Tauri command: `chat_send_message`
//!
//! Sends a user message to the on-device LLM and returns `Ok(())`
//! immediately. The actual reply (or error) is delivered to the frontend
//! via the `chat_reply` Tauri event emitted from a spawned async task.

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
))]
use {
    super::{resolved_model_config, sampling_config, CHAT_SYSTEM_PROMPT},
    ed_agent_tauri::EdState,
    log::{error, info},
    std::sync::atomic::{AtomicU64, Ordering},
    tauri::{AppHandle, State},
};

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
)))]
use log::debug;

/// Distinguishes turns in `chat_text_delta` and `chat_reply` payloads.
#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
))]
static NEXT_TURN: AtomicU64 = AtomicU64::new(1);

/// Send a user message to Siti and receive an assistant reply.
///
/// **Fire-and-return-immediately design**: this command returns `Ok(())`
/// as soon as the inference task is spawned. The actual reply (or error)
/// is delivered to the frontend via the `chat_reply` Tauri event
/// (`EVENT_CHAT_REPLY`).
///
/// ## Why events instead of a blocking return?
///
/// On Android, the Tauri IPC bridge stores the JS-side `invoke()` resolve
/// callback in a V8 `Map`.  Android's WebView GC can collect that entry
/// while the command is still running, especially on budget SoCs where
/// GGUF inference takes 60-300 seconds.  Emitting an event from a spawned
/// task sidesteps the GC entirely.
///
/// While the model generates, the reply also arrives piece by piece as
/// `chat_text_delta` events; `chat_reply` then carries the whole text.
#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
))]
#[tauri::command]
pub async fn chat_send_message(
    app: AppHandle,
    state: State<'_, EdState>,
    message: String,
) -> Result<(), String> {
    // ── 1. Lazy-load the model if not already cached ──────────────────────
    // Ed reports `Loading`, then `Ready` or `Error`.
    if !state.ed().is_loaded().await {
        info!("No chat model loaded; lazy-loading default model.");

        resolved_model_config()
            .load(
                state.ed(),
                Some(CHAT_SYSTEM_PROMPT.to_string()),
                Some(sampling_config()),
            )
            .await
            .map_err(|e| {
                let msg = format!("Failed to lazy-load chat model: {}", e);
                error!("{}", msg);
                msg
            })?;
    }

    // ── 2. Run the turn on a spawned task; this command returns at once ───
    // `submit` emits `chat_text_delta` while generating and `chat_reply` at
    // the end, with `{id, session, reply, duration, error}`.
    info!(
        "Chat inference DISPATCH history_turns={} message_chars={}",
        state.ed().history().await.len(),
        message.chars().count()
    );
    let id = NEXT_TURN.fetch_add(1, Ordering::Relaxed).to_string();
    state.submit(app, id, message);

    Ok(())
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
)))]
#[tauri::command]
pub async fn chat_send_message(_message: String) -> Result<(), String> {
    debug!("Siti chat is not supported on this platform.");
    Err("Siti chat is not supported on this platform.".to_string())
}
