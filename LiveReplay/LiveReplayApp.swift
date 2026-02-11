//
//  LiveReplayApp.swift
//  LiveReplay
//
//  Created by Albert Soong on 7/21/25.
//

import SwiftUI

@main
struct LiveReplayApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                PlaybackManager.shared.pausePlayer()
                CameraManager.shared.stopForBackground()

            case .active:
                CameraManager.shared.startAfterForeground()

            default:
                break
            }
        }
    }
}
