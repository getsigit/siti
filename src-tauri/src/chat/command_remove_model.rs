//! Tauri command `chat_remove_model`: deletes a downloaded model's weights.
//!
//! Removes the model's directory from the local HuggingFace cache to free disk
//! space. If the model being removed is the one currently loaded in memory, it
//! is unloaded first so the engine doesn't keep a now-orphaned model resident.

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
))]
use {
    super::{resolved_model_config, SELECTED_MODEL},
    ed_agent_tauri::EdState,
    log::{error, info},
    tauri::State,
};

/// Delete the locally cached weights for `model_id` (a HuggingFace repo id from
/// `chat_list_models`). Unloads the model first if it is currently loaded.
#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
))]
#[tauri::command]
pub async fn chat_remove_model(
    state: State<'_, EdState>,
    model_id: String,
) -> Result<String, String> {
    // If we're deleting the model that's currently loaded/selected, unload it
    // first so the engine isn't left holding weights we're about to remove.
    let is_selected = SELECTED_MODEL
        .lock()
        .map(|g| *g == model_id)
        .unwrap_or(false);

    if is_selected && state.ed().is_loaded().await {
        let display_name = resolved_model_config().display_name();
        // Ed reports the `Unloaded` transition.
        state.ed().unload().await;
        info!("Unloaded {display_name} before removing its weights.");
    }

    onde::hf_cache::delete_local_hf_model(model_id.clone()).map_err(|e| {
        let msg = format!("Failed to remove model {model_id}: {e}");
        error!("{msg}");
        msg
    })?;

    let msg = format!("Removed downloaded weights for {model_id}.");
    info!("{msg}");
    Ok(msg)
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
)))]
#[tauri::command]
pub async fn chat_remove_model(_model_id: String) -> Result<String, String> {
    log::debug!("Model management is not supported on this platform.");
    Err("Model management is not supported on this platform.".to_string())
}
