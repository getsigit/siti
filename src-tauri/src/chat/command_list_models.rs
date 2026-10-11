//! Tauri command: `chat_list_models`
//!
//! Returns the on-device models the user can switch between, sourced from the
//! onde SDK's `SUPPORTED_MODEL_INFO` catalogue (filtered to the subset the
//! engine can actually load), with the currently selected model flagged.

use super::ModelInfo;

/// Normalise a model description for Apple builds.
///
/// The shared onde model catalogue is cross-platform and also names sibling
/// products, so its descriptions mention Android/Windows/Linux and "siGit Code".
/// Apple's App Store Review Guideline 2.3.10 (Accurate Metadata) forbids
/// referencing other platforms in an iOS/macOS app's UI or metadata, so on
/// Apple builds we drop those mentions before the text reaches Settings. We
/// also neutralise the cross-product reference, which would only confuse a Siti
/// user. Apple's own platforms (iOS, macOS, tvOS) are kept.
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn sanitize_description(desc: &str) -> String {
    desc.replace("iOS & Android", "iOS")
        .replace("macOS & Android", "macOS")
        .replace("macOS, Linux, and Windows", "macOS")
        .replace(", Linux, and Windows", "")
        .replace(", Linux and Windows", "")
        .replace(" & Android", "")
        .replace(" and Android", "")
        .replace("siGit Code", "coding tasks")
}

/// On non-Apple builds the catalogue text is already accurate, so pass it through.
#[cfg(any(target_os = "android", target_os = "windows"))]
fn sanitize_description(desc: &str) -> String {
    desc.to_string()
}

/// List the supported on-device models, smallest first, with the currently
/// selected model marked. Used to populate the Settings model dropdown.
#[cfg(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
))]
#[tauri::command]
pub async fn chat_list_models() -> Vec<ModelInfo> {
    use super::{config_for_model_id, is_model_downloaded, SELECTED_MODEL};

    let selected = SELECTED_MODEL.lock().map(|g| g.clone()).unwrap_or_default();

    let mut models: Vec<ModelInfo> = crate::inference::models::SUPPORTED_MODEL_INFO
        .iter()
        // Only include models the engine can build a loadable config for.
        .filter_map(|info| {
            config_for_model_id(info.id).map(|cfg| ModelInfo {
                id: info.id.to_string(),
                name: info.name.to_string(),
                org: info.org.to_string(),
                description: sanitize_description(info.description),
                approx_memory: cfg.approx_memory,
                size_bytes: Some(info.expected_size_bytes),
                is_downloaded: is_model_downloaded(info.id, info.expected_size_bytes),
                is_selected: info.id == selected,
            })
        })
        .collect();

    // Qwen 3 UQFF models: pre-quantised (Q4K) safetensors loaded via onde's
    // UQFF path on every inference platform. Not in onde's GGUF catalogue, so
    // they're appended here from Siti's own `UQFF_MODELS` table. A few ~45 GB
    // entries are marked `desktop_only` and skipped on iOS/Android, where
    // neither the storage nor the memory budget could realistically fit them.
    {
        use super::UQFF_MODELS;
        for entry in UQFF_MODELS {
            if entry.desktop_only && !cfg!(any(target_os = "macos", target_os = "windows")) {
                continue;
            }
            models.push(ModelInfo {
                id: entry.id.to_string(),
                name: entry.name.to_string(),
                org: "Qwen / Alibaba".to_string(),
                description: sanitize_description(entry.description),
                approx_memory: entry.approx_memory.to_string(),
                size_bytes: Some(entry.expected_size_bytes),
                is_downloaded: is_model_downloaded(entry.id, entry.expected_size_bytes),
                is_selected: entry.id == selected,
            });
        }
    }

    // Gemma is not in onde's GGUF catalogue: mistral.rs's GGUF loader has no
    // Gemma architecture, so Gemma can only load via the ISQ (safetensors)
    // path, which is Metal-only. Offer it on macOS exclusively.
    #[cfg(target_os = "macos")]
    {
        use super::{gemma2_2b_isq_config, GEMMA2_2B_IT_ISQ_ID};
        const GEMMA2_2B_EXPECTED_BYTES: u64 = 5_228_717_512;
        let cfg = gemma2_2b_isq_config();
        models.push(ModelInfo {
            id: GEMMA2_2B_IT_ISQ_ID.to_string(),
            name: "Gemma 2 2B (ISQ)".to_string(),
            org: "Google".to_string(),
            description: sanitize_description(
                "Google's Gemma 2 2B Instruct, quantised on-device to 4-bit (~1.6 GB). \
                 Loaded from safetensors via ISQ; requires 8+ GB RAM.",
            ),
            approx_memory: cfg.approx_memory,
            // Full bf16 safetensors download before in-situ quantisation (~5.2 GB).
            size_bytes: Some(GEMMA2_2B_EXPECTED_BYTES),
            is_downloaded: is_model_downloaded(GEMMA2_2B_IT_ISQ_ID, GEMMA2_2B_EXPECTED_BYTES),
            is_selected: GEMMA2_2B_IT_ISQ_ID == selected,
        });
    }

    // Smallest (most device-friendly) first.
    models.sort_by_key(|m| m.size_bytes.unwrap_or(u64::MAX));
    models
}

#[cfg(not(any(
    target_os = "macos",
    target_os = "ios",
    target_os = "android",
    target_os = "windows"
)))]
#[tauri::command]
pub async fn chat_list_models() -> Vec<ModelInfo> {
    log::debug!("On-device models are not supported on this platform.");
    Vec::new()
}
