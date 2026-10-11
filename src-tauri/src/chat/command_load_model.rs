//! Tauri command `chat_load_model`: loads the on-device chat model.
//!
//! Siti is fully offline: it loads the platform-default GGUF model directly.
//! There is no operator-assigned model and no app credentials involved. The
//! only network access is the one-time HuggingFace download of the model
//! weights into the shared App Group cache.

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
))]
use {
    super::{fmt_duration, resolved_model_config, sampling_config, CHAT_SYSTEM_PROMPT},
    ed_agent_tauri::EdState,
    log::{error, info},
    tauri::State,
};

/// Load the platform-default chat model into memory. Ed reports the
/// `Loading` -> `Ready`/`Error` transitions as `chat_status_changed`.
#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
))]
#[tauri::command]
pub async fn chat_load_model(state: State<'_, EdState>) -> Result<String, String> {
    let config = resolved_model_config();
    let display_name = config.display_name();
    info!("chat_load_model: loading on-device model {}", display_name);

    let elapsed = config
        .load(
            state.ed(),
            Some(CHAT_SYSTEM_PROMPT.to_string()),
            Some(sampling_config()),
        )
        .await
        .map_err(|e| {
            let msg = format!("Failed to load chat model: {}", e);
            error!("{}", msg);
            msg
        })?;

    let msg = format!(
        "Chat model {} loaded in {}",
        display_name,
        fmt_duration(elapsed)
    );
    info!("{}", msg);
    Ok(msg)
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
)))]
#[tauri::command]
pub async fn chat_load_model() -> Result<String, String> {
    log::debug!("Chat model is not supported on this platform.");
    Err("Chat model is not supported on this platform.".to_string())
}
