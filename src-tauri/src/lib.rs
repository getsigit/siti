pub mod app_info;
pub mod chat;
pub mod constants;
pub mod events;
pub mod setup;

/// Re-export onde's inference helpers so `crate::inference::*` paths work.
pub mod inference {
    pub use onde::inference::{models, token};
}

use app_info::app_build_version;
use chat::{
    chat_clear_history, chat_download_progress, chat_get_history, chat_get_status,
    chat_list_models, chat_load_model, chat_remove_model, chat_send_message, chat_set_model,
    chat_unload_model,
};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(
            tauri_plugin_log::Builder::new()
                .level(log::LevelFilter::Info)
                // Quiet the chattiest inference/download dependencies.
                .level_for("tokenizers", log::LevelFilter::Warn)
                .level_for("hf_hub", log::LevelFilter::Warn)
                .level_for("rustls", log::LevelFilter::Warn)
                .level_for("hyper", log::LevelFilter::Warn)
                .level_for("candle_core", log::LevelFilter::Warn)
                .level_for("candle_nn", log::LevelFilter::Warn)
                .target(tauri_plugin_log::Target::new(
                    tauri_plugin_log::TargetKind::Stdout,
                ))
                .build(),
        )
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            // Disable telemetry + redirect the model cache into the shared
            // App Group container. Must run before any onde / hf-hub code.
            setup::setup(app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            // Chat commands: fully on-device LLM inference
            chat_load_model,
            chat_unload_model,
            chat_get_status,
            chat_send_message,
            chat_clear_history,
            chat_get_history,
            chat_list_models,
            chat_set_model,
            chat_remove_model,
            chat_download_progress,
            // App metadata
            app_build_version,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
