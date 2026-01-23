//
//  SettingsManager.swift
//  LiveReplay
//
//  Created by Albert Soong on 1/30/25.
//

import Foundation

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    @Published var showPose: Bool = true
    @Published var voiceOn: Bool = true
    @Published var autoShowReplay: Bool = true
    @Published var autoSaveReplay: Bool = true
    @Published var resizeAspectFill: Bool = false

    private init() {}
}
