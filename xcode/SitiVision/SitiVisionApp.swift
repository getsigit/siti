//
//  SitiVisionApp.swift
//  Siti AI visionOS
//

import SwiftUI

@main
struct SitiVisionApp: App {

    init() {
        // Must be called before any EdAgent interaction so the Rust
        // core can find its cache directories inside the app sandbox.
        setupInferenceEnvironment()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 900, height: 700)
    }
}
