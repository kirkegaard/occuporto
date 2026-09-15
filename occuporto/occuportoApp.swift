//
//  occuportoApp.swift
//  occuporto
//
//  Created by Christian Kirkegaard on 11/08/2026.
//

import SwiftUI

@main
struct occuportoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No real window is used — the menu bar status item and its
        // popover are managed entirely by `AppDelegate`. `Settings` is
        // used here purely because SwiftUI's `App` protocol requires at
        // least one `Scene`, and `Settings` doesn't show anything on
        // launch (unlike `WindowGroup`).
        Settings {
            EmptyView()
        }
    }
}
