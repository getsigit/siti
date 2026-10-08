//
//  InferenceEnvironment.swift
//  Siti AI visionOS
//

import Foundation

/// Points `HF_HOME` and `HF_HUB_CACHE` at a writable location inside the app
/// sandbox. Uses the same `group.com.ondeinference.apps` App Group as the
/// Tauri build of Siti (see `src-tauri/src/setup/setup_application_filesystem.rs`)
/// so a model downloaded by one Siti app on this device is reused by the
/// other instead of being fetched twice. Falls back to the app's own
/// Application Support directory if the group is unavailable.
///
/// Call this once at launch, before creating an `EdAgent`.
func setupInferenceEnvironment() {
    let fm = FileManager.default

    let base: URL = fm.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.ondeinference.apps"
    ) ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    let hfHome     = base.appendingPathComponent("models", isDirectory: true)
    let hfHubCache = hfHome.appendingPathComponent("hub",    isDirectory: true)
    try? fm.createDirectory(at: hfHubCache, withIntermediateDirectories: true)

    setenv("HF_HOME",      hfHome.path,     1)
    setenv("HF_HUB_CACHE", hfHubCache.path, 1)

    // Make sure TMPDIR points inside the sandbox for the Rust side.
    let tmp = base.appendingPathComponent("tmp", isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    setenv("TMPDIR", tmp.path, 1)
}
