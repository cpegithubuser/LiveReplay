//
//  OnScreenLogger.swift
//  LiveReplay
//

import SwiftUI
import Combine

/// Shared on-screen logger. Call `OnScreenLog("message")` from anywhere.
/// Set `isEnabled` to false to turn off on-screen logging (no-op and overlay hidden).
final class OnScreenLogger: ObservableObject {
    static let shared = OnScreenLogger()
    
    /// When false, OnScreenLog() does nothing and the overlay is hidden.
    var isEnabled: Bool = false
    
    /// When false, the log panel is hidden; a "Show log" button remains to show it again.
    @Published var isOverlayVisible: Bool = true
    
    @Published private(set) var messages: [String] = []
    private let maxMessages = 100
    
    private init() {}
    
    func log(_ message: String) {
        guard isEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.messages.append(message)
            if self.messages.count > self.maxMessages {
                self.messages.removeFirst()
            }
        }
    }
    
    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.messages = []
        }
    }
}

func OnScreenLog(_ message: String) {
    OnScreenLogger.shared.log(message)
}

struct OnScreenLogOverlayView: View {
    @ObservedObject private var logger = OnScreenLogger.shared
    
    var body: some View {
        if !logger.isEnabled {
            EmptyView()
        } else if logger.isOverlayVisible {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button("Hide") {
                        logger.isOverlayVisible = false
                    }
                    .font(.caption)
                    .foregroundColor(.white)
                    Button("Clear") {
                        logger.clear()
                    }
                    .font(.caption)
                    .foregroundColor(.white)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logger.messages.enumerated()), id: \.offset) { _, msg in
                            Text(msg)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 180)
                .background(Color.black.opacity(0.7))
                .cornerRadius(6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
            .background(Color.clear)
        } else {
            Button("Show log") {
                logger.isOverlayVisible = true
            }
            .font(.caption)
            .foregroundColor(.white)
            .padding(6)
            .background(Color.black.opacity(0.6))
            .cornerRadius(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
        }
    }
}
