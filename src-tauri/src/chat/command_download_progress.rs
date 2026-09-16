//! Tauri command `chat_download_progress`: bytes fetched so far for a model.
//!
//! Weight downloads run inside mistral.rs, which reports progress only to an
//! `indicatif` bar destined for the log — nothing the WebView can observe. The
//! HF cache directory is therefore the one shared surface between the transfer
//! and the UI, so Settings polls this while a model is loading to turn an
//! indeterminate spinner into a real percentage.
//!
//! A 646 MB UQFF model on a phone hotspot takes ten minutes or more; without
//! this the panel is indistinguishable from a hang for that whole time.

/// Bytes of `model_id`'s weights present in the local HF cache, counting the
/// partially written file of a download still in flight.
///
/// The caller already knows the model's expected total (`ModelInfo.size_bytes`)
/// and computes the percentage from it, so this stays a single number rather
/// than duplicating the size table on both sides of the IPC boundary.
///
/// Returns `0` for an unknown id or an untouched cache, which the frontend
/// renders as an indeterminate state — the same thing it showed before.
#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
))]
#[tauri::command]
pub async fn chat_download_progress(model_id: String) -> u64 {
    super::model_downloaded_bytes(&model_id)
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
)))]
#[tauri::command]
pub async fn chat_download_progress(_model_id: String) -> u64 {
    0
}
