//! Tauri command `chat_set_model`: switches the active on-device model.
//!
//! Updates the selected model, unloads any currently loaded model, and loads
//! the new one. Like `chat_send_message`, this returns `Ok(())` as soon as the
//! work is dispatched: switching can trigger a multi-gigabyte HuggingFace
//! download, so progress and completion are reported via the
//! `chat_status_changed` event (Loading → Ready, or Error) rather than a
//! blocking return that the WebView could GC out from under us.

#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
))]
use {
    super::{
        fmt_duration, resolve_model_id, resolved_model_config, sampling_config, CHAT_SYSTEM_PROMPT,
        SELECTED_MODEL,
    },
    ed_agent_tauri::EdState,
    log::{error, info},
    tauri::State,
};

/// Switch Siti to the model identified by `model_id` (a HuggingFace repo id
/// from `chat_list_models`). The new model is loaded asynchronously; watch the
/// `chat_status_changed` event for `Loading` → `Ready`/`Error`.
#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
))]
#[tauri::command]
pub async fn chat_set_model(state: State<'_, EdState>, model_id: String) -> Result<(), String> {
    // ── 1. Validate & resolve the requested model ────────────────────────
    let display_name = resolve_model_id(&model_id)
        .ok_or_else(|| format!("Unknown or unsupported model id: {model_id}"))?
        .display_name();

    // ── 2. Persist the selection so resolved_model_config()/sampling_config() agree ─
    // NB: never hold the std Mutex guard across an `.await` (it would make this
    // command future `!Send`), so resolve the loaded-state first.
    let already_loaded = state.ed().is_loaded().await;
    {
        let mut selected = SELECTED_MODEL
            .lock()
            .map_err(|e| format!("Failed to update selected model: {e}"))?;
        if *selected == model_id && already_loaded {
            info!("Model {display_name} is already selected and loaded; nothing to do.");
            return Ok(());
        }
        *selected = model_id.clone();
    }

    info!("chat_set_model: switching to {display_name} ({model_id})");

    // ── 3. Swap models off-thread; report progress via events ────────────
    // Re-resolve from the (now-persisted) selection inside the task so the
    // GGUF/ISQ dispatch matches exactly what `chat_send_message` would load.
    let ed = state.shared();
    tokio::task::spawn(async move {
        if ed.is_loaded().await {
            // The engine's own unload: Ed's `unload` would report `Unloaded`
            // and flash the UI before the load below reports `Loading`.
            ed.engine().unload_model().await;
        }

        // Ed reports `Loading`, then `Ready` or `Error`.
        match resolved_model_config()
            .load(
                &ed,
                Some(CHAT_SYSTEM_PROMPT.to_string()),
                Some(sampling_config()),
            )
            .await
        {
            Ok(elapsed) => info!("Model {display_name} loaded in {}", fmt_duration(elapsed)),
            Err(e) => error!("Failed to load model {display_name}: {e}"),
        }
    });

    Ok(())
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
)))]
#[tauri::command]
pub async fn chat_set_model(_model_id: String) -> Result<(), String> {
    log::debug!("Model switching is not supported on this platform.");
    Err("Model switching is not supported on this platform.".to_string())
}
