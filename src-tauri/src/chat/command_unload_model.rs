//! Tauri command `chat_unload_model`: frees the chat model from memory.

use log::debug;

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
))]
use {super::resolved_model_config, ed_agent_tauri::EdState, log::info, tauri::State};

/// Unload the chat model from memory to free resources.
#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
))]
#[tauri::command]
pub async fn chat_unload_model(state: State<'_, EdState>) -> Result<String, String> {
    if state.ed().is_loaded().await {
        let display_name = resolved_model_config().display_name();
        // Ed reports the `Unloaded` transition.
        state.ed().unload().await;
        info!("Chat model unloaded: {}", display_name);
        Ok(format!("Chat model {} unloaded.", display_name))
    } else {
        debug!("No chat model was loaded.");
        Ok("No chat model was loaded.".to_string())
    }
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
)))]
#[tauri::command]
pub async fn chat_unload_model() -> Result<String, String> {
    debug!("Chat model is not supported on this platform.");
    Ok("No chat model was loaded.".to_string())
}
