pub mod setup_application_filesystem;

use setup_application_filesystem::setup_application_filesystem;
use tauri::App;

/// Run all setup steps.  Called from `tauri::Builder::setup()`.
///
/// Both steps must run **before** any `onde` / `hf-hub` / `mistral.rs` code,
/// i.e. before the managed `EdState` is created.
pub fn setup(app: &App) -> Result<(), Box<dyn std::error::Error>> {
    // Siti runs fully offline. Disable onde's pulse telemetry so no usage
    // beacons are ever sent, regardless of whether GresIQ credentials happen
    // to be embedded in the onde build. `ChatEngine` reads this env var when
    // it initialises its (optional) pulse client, which now happens when Ed
    // creates the engine.
    std::env::set_var("ONDE_DISABLE_PULSE", "1");

    // Redirect HF_HOME, HF_HUB_CACHE, and TMPDIR into the shared App Group
    // container so downloaded models are shared across Onde apps and remain
    // writable inside the iOS / macOS sandbox.
    setup_application_filesystem(app)?;

    Ok(())
}
