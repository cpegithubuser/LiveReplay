//
//  SettingsView.swift
//  LiveReplay
//
//  Created by Albert Soong on 1/29/25.
//

import SwiftUI
import AVFoundation

struct SettingsView: View {

    @ObservedObject var cameraManager = CameraManager.shared
    @Binding public var showSettings: Bool

    @State private var draftDeviceUniqueID: String = ""
    @State private var draftFormatIndex: Int = 0
    @State private var userDidPickFormat: Bool = false

    enum VideoSize: String, CaseIterable, Identifiable {
        case k4 = "4K"
        case p1080 = "1080p"
        case p720 = "720p"
        var id: String { rawValue }
    }

    enum FPSChoice: Int, CaseIterable, Identifiable {
        case fps30 = 30
        case fps60 = 60
        case fps120 = 120
        case fps240 = 240
        var id: Int { rawValue }
        var label: String { "\(rawValue)fps" }
    }

    @State private var draftVideoSize: VideoSize = .p1080
    @State private var draftFPS: FPSChoice = .fps30

    // MARK: - Draft discovery (no side effects on CameraManager until Update)

    private var draftDevices: [AVCaptureDevice] {
        // Single source of truth: CameraManager preferred cameras across front/back.
        return cameraManager.discoverPreferredDevices()
    }

    private var draftSelectedDevice: AVCaptureDevice? {
        draftDevices.first(where: { $0.uniqueID == draftDeviceUniqueID }) ?? draftDevices.first
    }

    private var draftFormats: [AVCaptureDevice.Format] {
        guard let device = draftSelectedDevice else { return [] }
        // Single source of truth: CameraManager discovery helpers.
        return cameraManager.discoverFormats(allFormats: false, device: device)
    }

    private func sizeCategory(for format: AVCaptureDevice.Format) -> VideoSize? {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        switch (dims.width, dims.height) {
        case (3840, 2160): return .k4
        case (_, 1080):    return .p1080
        case (_, 720):     return .p720
        default:           return nil
        }
    }

    private func formatSupports(_ fps: FPSChoice, _ format: AVCaptureDevice.Format) -> Bool {
        let ranges = format.videoSupportedFrameRateRanges
        let val = Double(fps.rawValue)
        return ranges.contains { val >= $0.minFrameRate && val <= $0.maxFrameRate }
    }

    private func fpsBucket(for format: AVCaptureDevice.Format) -> FPSChoice {
        let fpsMax = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        if fpsMax >= 240 { return .fps240 }
        if fpsMax >= 120 { return .fps120 }
        if fpsMax >= 60  { return .fps60 }
        return .fps30
    }

    private var availableSizesForSelectedFPS: Set<VideoSize> {
        Set(draftFormats.compactMap { fmt in
            guard let size = sizeCategory(for: fmt) else { return nil }
            return fpsBucket(for: fmt) == draftFPS ? size : nil
        })
    }

    private var availableFPSForSelectedSize: Set<FPSChoice> {
        var result = Set<FPSChoice>()
        for fmt in draftFormats {
            guard sizeCategory(for: fmt) == draftVideoSize else { continue }
            result.insert(fpsBucket(for: fmt))
        }
        return result
    }

    private func isFormatEnabled(_ fmt: AVCaptureDevice.Format) -> Bool {
        guard sizeCategory(for: fmt) == draftVideoSize else { return false }
        return fpsBucket(for: fmt) == draftFPS
    }

    private var matchingFormatIndices: [Int] {
        draftFormats.indices.filter { idx in
            isFormatEnabled(draftFormats[idx])
        }
    }

    private func formatPreferenceKey(_ format: AVCaptureDevice.Format) -> (Int, Int) {
        // Lower is better.
        // Prefer non-HDR (0) over HDR (1), and prefer binned (0) over not binned (1).
        let hdrKey = format.isVideoHDRSupported ? 1 : 0
        let binnedKey = format.isVideoBinned ? 0 : 1
        return (hdrKey, binnedKey)
    }

    private func preferredMatchingFormatIndex() -> Int? {
        let formats = draftFormats
        let matching = matchingFormatIndices
        guard !matching.isEmpty else { return nil }

        return matching.min { a, b in
            let ka = formatPreferenceKey(formats[a])
            let kb = formatPreferenceKey(formats[b])
            if ka.0 != kb.0 { return ka.0 < kb.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            return a < b
        }
    }

    private func supportedFPSSet(for size: VideoSize) -> Set<FPSChoice> {
        var result = Set<FPSChoice>()
        for fmt in draftFormats {
            guard sizeCategory(for: fmt) == size else { continue }
            result.insert(fpsBucket(for: fmt))
        }
        return result
    }

    private func pickBestFPS(from set: Set<FPSChoice>) -> FPSChoice {
        let ordered: [FPSChoice] = [.fps240, .fps120, .fps60, .fps30]
        return ordered.first(where: { set.contains($0) }) ?? .fps30
    }

    private func pickBestAvailableFPS() -> FPSChoice {
        // Prefer higher fps if available
        return pickBestFPS(from: availableFPSForSelectedSize)
    }

    private func pickBestAvailableSize() -> VideoSize {
        // Prefer higher resolution if available
        let ordered: [VideoSize] = [.k4, .p1080, .p720]
        let avail = availableSizesForSelectedFPS
        return ordered.first(where: { avail.contains($0) }) ?? .p1080
    }

    private func clampDraftSizeFPSAndFormat() {
        // 1) Ensure size is compatible with selected fps
        if !availableSizesForSelectedFPS.contains(draftVideoSize) {
            draftVideoSize = pickBestAvailableSize()
        }

        // 2) Ensure fps is compatible with selected size
        if !availableFPSForSelectedSize.contains(draftFPS) {
            draftFPS = pickBestAvailableFPS()
        }

        // 3) Ensure the selected format matches both; otherwise pick the preferred matching index.
        if matchingFormatIndices.contains(draftFormatIndex) {
            // ok
        } else if let preferredIdx = preferredMatchingFormatIndex() {
            draftFormatIndex = preferredIdx
        } else {
            // No format matches current size+fps; fall back safely.
            draftFormatIndex = 0
        }
    }

    // User changed Size: always downgrade FPS as needed, then ensure format exists; if no formats for this size, downgrade Size.
    private func clampAfterSizeChange() {
        // For the newly-selected size, compute supported FPS.
        let supportedForSize = supportedFPSSet(for: draftVideoSize)

        // If this size exists but doesn't support the currently selected FPS, downgrade FPS.
        if !supportedForSize.isEmpty {
            if !supportedForSize.contains(draftFPS) {
                draftFPS = pickBestFPS(from: supportedForSize)
            }
        } else {
            // This size has no formats at all on this camera; fall back by downgrading size.
            draftVideoSize = pickBestAvailableSize()
            // Recompute supported FPS for the new size.
            let supported2 = supportedFPSSet(for: draftVideoSize)
            if !supported2.isEmpty, !supported2.contains(draftFPS) {
                draftFPS = pickBestFPS(from: supported2)
            }
        }

        // Ensure format matches size+fps; if none match, relax by downgrading FPS for this size.
        if matchingFormatIndices.isEmpty {
            let supported3 = supportedFPSSet(for: draftVideoSize)
            if !supported3.isEmpty {
                draftFPS = pickBestFPS(from: supported3)
            }
        }

        if !matchingFormatIndices.contains(draftFormatIndex) {
            draftFormatIndex = preferredMatchingFormatIndex() ?? 0
        }
    }

    // User changed FPS: keep FPS and downgrade Size/Format as needed, but if FPS is not supported at any size, downgrade FPS as a last resort.
    private func clampAfterFPSChange() {
        // If this FPS isn't supported at any size, downgrade FPS (last-resort safety).
        if availableSizesForSelectedFPS.isEmpty {
            // Find the highest FPS that yields at least one size.
            let ordered: [FPSChoice] = [.fps240, .fps120, .fps60, .fps30]
            if let best = ordered.first(where: { fps in
                // compute sizes for that fps
                let sizes = Set(draftFormats.compactMap { fmt -> VideoSize? in
                    guard let size = sizeCategory(for: fmt) else { return nil }
                    return formatSupports(fps, fmt) ? size : nil
                })
                return !sizes.isEmpty
            }) {
                draftFPS = best
            }
        }

        // Ensure size is compatible with selected fps (keeping FPS).
        if !availableSizesForSelectedFPS.contains(draftVideoSize) {
            draftVideoSize = pickBestAvailableSize()
        }

        // Ensure format matches size+fps; if none match, relax by downgrading size (already) then pick preferred match.
        if !matchingFormatIndices.contains(draftFormatIndex) {
            draftFormatIndex = preferredMatchingFormatIndex() ?? 0
        }
    }
    
    private func syncSizeFPSFromSelectedFormat() {
        let formats = draftFormats
        guard formats.indices.contains(draftFormatIndex) else { return }
        let fmt = formats[draftFormatIndex]
        if let size = sizeCategory(for: fmt) {
            draftVideoSize = size
        }
        // Keep FPS consistent with the selected format's FPS bucket.
        draftFPS = fpsBucket(for: fmt)
    }

    private func clampDraftDevice() {
        let devices = draftDevices
        if devices.isEmpty {
            draftDeviceUniqueID = ""
            return
        }
        if !devices.contains(where: { $0.uniqueID == draftDeviceUniqueID }) {
            draftDeviceUniqueID = devices.first?.uniqueID ?? ""
        }
    }
    private func clampDraftFormat() {
        // Keep legacy bounds safety, then enforce size/fps constraints.
        let formats = draftFormats
        if formats.isEmpty {
            draftFormatIndex = 0
            return
        }
        if !(0..<formats.count).contains(draftFormatIndex) {
            draftFormatIndex = 0
        }
        clampDraftSizeFPSAndFormat()
    }

    private func loadDraftsFromManager() {
        draftDeviceUniqueID = cameraManager.selectedDeviceUniqueID
        draftFormatIndex = cameraManager.selectedFormatIndex

        // Primary seed: derive Size from selected format.
        if cameraManager.availableFormats.indices.contains(cameraManager.selectedFormatIndex) {
            let fmt = cameraManager.availableFormats[cameraManager.selectedFormatIndex]
            if let size = sizeCategory(for: fmt) {
                draftVideoSize = size
            }
        }

        // Primary seed: derive FPS bucket from the manager's selected frame rate.
        let currentFPS = Int(round(cameraManager.selectedFrameRate))
        if currentFPS >= 240 { draftFPS = .fps240 }
        else if currentFPS >= 120 { draftFPS = .fps120 }
        else if currentFPS >= 60 { draftFPS = .fps60 }
        else { draftFPS = .fps30 }

        clampDraftDevice()
        clampDraftFormat()
        clampDraftSizeFPSAndFormat()
        userDidPickFormat = false
    }

    private func applyDraftSelections() {
        guard let device = draftSelectedDevice else { return }

        // Derive front/back from the chosen device.
        let newLocation: CameraManager.CameraPosition = (device.position == .front) ? .front : .back

        // Apply location first; CameraManager refreshes its device list asynchronously.
        cameraManager.cameraLocation = newLocation

        // Apply device + format on the next main runloop so CameraManager has a chance
        // to refresh its device list for the new location.
        DispatchQueue.main.async {
            self.cameraManager.selectedDeviceUniqueID = device.uniqueID

            // selectedDeviceUniqueID didSet triggers updateAvailableFormats(); apply format index after that.
            DispatchQueue.main.async {
                self.cameraManager.selectedFormatIndex = self.draftFormatIndex
            }
        }
    }

    private func formatLabel(_ format: AVCaptureDevice.Format) -> String {
        let desc = format.formatDescription
        let mediaSub = CMFormatDescriptionGetMediaSubType(desc)
        let b0 = UInt8((mediaSub >> 24) & 0xFF)
        let b1 = UInt8((mediaSub >> 16) & 0xFF)
        let b2 = UInt8((mediaSub >>  8) & 0xFF)
        let b3 = UInt8( mediaSub        & 0xFF)
        let fourcc = String(bytes: [b0,b1,b2,b3], encoding: .ascii) ?? "?"
        let dims = CMVideoFormatDescriptionGetDimensions(desc)

        let sizeLabel: String = {
            switch (dims.width, dims.height) {
            case (3840, 2160): return "4K"
            case (_, 1080):    return "1080p"
            case (_, 720):     return "720p"
            default:           return "\(dims.width)x\(dims.height)"
            }
        }()

        let fpsLabel: String = {
            switch fpsBucket(for: format) {
            case .fps240: return "240fps"
            case .fps120: return "120fps"
            case .fps60:  return "60fps"
            case .fps30:  return "30fps"
            }
        }()

        let fov = String(format: "%.1f°", format.videoFieldOfView)

        // Extra capability flags
        let hdrLabel = format.isVideoHDRSupported ? "HDR" : nil
        let binnedLabel = format.isVideoBinned ? "Binned" : nil
        let extras = [hdrLabel, binnedLabel].compactMap { $0 }
        let extrasLabel = extras.isEmpty ? "" : " • \(extras.joined(separator: "/"))"

        return "\(sizeLabel) • \(fpsLabel) • \(fourcc) • \(fov)\(extrasLabel)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Camera", selection: $draftDeviceUniqueID) {
                        ForEach(draftDevices, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: draftDeviceUniqueID) { _ in
                        withAnimation(.none) {
                            userDidPickFormat = false
                            // Draft-only: switching camera changes available formats.
                            clampDraftDevice()

                            // Keep current size/fps if possible; otherwise clamp to something valid.
                            clampDraftSizeFPSAndFormat()

                            // Ensure the format selection is valid for the chosen camera + size + fps.
                            if !matchingFormatIndices.contains(draftFormatIndex) {
                                draftFormatIndex = preferredMatchingFormatIndex() ?? 0
                            }
                        }
                    }

                    Picker("Size", selection: $draftVideoSize) {
                        ForEach(VideoSize.allCases) { size in
                            let enabled = availableSizesForSelectedFPS.contains(size)
                            Text(enabled ? size.rawValue : "\(size.rawValue) ✶")
                                .opacity(enabled ? 1.0 : 0.20)
                                .italic(!enabled)
                                .tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draftVideoSize) { _ in
                        withAnimation(.none) {
                            userDidPickFormat = false
                            // Size changed: keep Size, downgrade FPS/Format as needed.
                            clampAfterSizeChange()
                        }
                    }

                    Picker("FPS", selection: $draftFPS) {
                        ForEach(FPSChoice.allCases) { fps in
                            let enabled = availableFPSForSelectedSize.contains(fps)
                            Text(enabled ? fps.label : "\(fps.label) ✶")
                                .opacity(enabled ? 1.0 : 0.20)
                                .italic(!enabled)
                                .tag(fps)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draftFPS) { _ in
                        withAnimation(.none) {
                            userDidPickFormat = false
                            // FPS changed: keep FPS, downgrade Size/Format as needed.
                            clampAfterFPSChange()
                        }
                    }

                }

                Section {
                    let formats = draftFormats
                    let matching = matchingFormatIndices
                    if formats.isEmpty {
                        Text("No formats available")
                            .foregroundColor(.secondary)
                    } else if matching.isEmpty {
                        Text("No formats match the selected size/FPS")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Format", selection: $draftFormatIndex) {
                            ForEach(matching, id: \.self) { idx in
                                Text(formatLabel(formats[idx]))
                                    .tag(idx)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: draftFormatIndex) { _ in
                            withAnimation(.none) {
                                userDidPickFormat = true
                                // If user picked a format, update size/fps to match it (draft-only).
                                syncSizeFPSFromSelectedFormat()
                                clampDraftSizeFPSAndFormat()
                            }
                        }
                    }
                }
            }
            .transaction { txn in
                txn.animation = nil
            }
            .navigationTitle("Camera Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        // Restore manager selections to whatever they were when the sheet opened.
                        loadDraftsFromManager()
                        showSettings = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Update") {
                        applyDraftSelections()
                        showSettings = false
                    }
                    .disabled(draftDeviceUniqueID.isEmpty)
                }
            }
            .onAppear {
                loadDraftsFromManager()
            }
        }
    }
}
