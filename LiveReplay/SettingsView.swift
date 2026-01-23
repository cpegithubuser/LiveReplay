//
//  SettingsView.swift
//  LiveReplay
//
//  Created by Albert Soong on 1/29/25.
//

import SwiftUI
import AVKit

struct SettingsView: View {
    
    @ObservedObject var settings = SettingsManager.shared
    @ObservedObject var cameraManager = CameraManager.shared
    @Binding public var showSettings: Bool
    
    //@State public var mirroredReplay = true
    var body: some View {
        ZStack {
            Color.white
            ScrollView {
                VStack{
                    HStack {
                        Text("ABOUT").bold()
                            .font(Font.custom("Helvetica Neue", size: 30))
                            .padding(7)
                            .foregroundColor(Color.white)
                            .background(Color.gray)
                            .cornerRadius(12)
                            .padding(10)
                        Text("For more on how to use Archery Vision, visit www.archeryvision.com")
                            .font(Font.custom("Helvetica Neue", size: 20))
                            .padding(7)
                            .foregroundColor(Color.black)
                        Spacer()
                        Button {
                            showSettings = false
                        } label: {
                            Text("Close")
                                .font(Font.custom("Helvetica Neue", size: 20.0))
                                .padding(7)
                                .foregroundColor(Color.black)
                                .background(Color.yellow)
                                .cornerRadius(12)
                                .padding(12)
                        }
                        
                    }
                    Divider()
                    
                    Spacer()
                    
                    
                    
                    
                                    HStack {
                                        Text("Replay Orientation:")
                                            .font(Font.custom("Helvetica Neue", size: 20.0))
                                            .padding(7)
                                            .foregroundColor(Color.black)
                                            .padding(20)
                                        Button {
                                            cameraManager.mirroredReplay = (cameraManager.mirroredReplay == true) ? false : true
                                        } label: {
                                            Text((cameraManager.mirroredReplay == true) ? "Mirrored" : "Not Mirrored")
                                                .font(Font.custom("Helvetica Neue", size: 20.0))
                                                .padding(7)
                                                .foregroundColor(Color.black)
                                                .background(Color.yellow)
                                                .cornerRadius(12)
                                                .padding(12)
                                        }
                                        Spacer()
                                    }
                    HStack {
                        Text("Camera Selection:")
                            .font(Font.custom("Helvetica Neue", size: 20.0))
                            .padding(7)
                            .foregroundColor(Color.black)
                            .padding(20)
                        Button {
                            cameraManager.cameraLocation = (cameraManager.cameraLocation == .back) ? .front : .back
                        } label: {
                            Text((cameraManager.cameraLocation == .back) ? "Back Camera" : "Front Camera")
                                .font(Font.custom("Helvetica Neue", size: 20.0))
                                .padding(7)
                                .foregroundColor(Color.black)
                                .background(Color.yellow)
                                .cornerRadius(12)
                                .padding(12)
                        }
                    }
                    VStack(alignment: .leading) {
                      Text("Camera Lens:").font(.headline)
                      Picker("Lens", selection: $cameraManager.selectedDeviceUniqueID) {
                        ForEach(cameraManager.availableDevices, id: \.uniqueID) { device in
                          Text(device.localizedName).tag(device.uniqueID)
                        }
                      }
                      .pickerStyle(SegmentedPickerStyle())
                      .onChange(of: cameraManager.selectedDeviceUniqueID) { _ in
                        // when the user picks a new lens, restart
                        cameraManager.initializeCaptureSession()
                      }
                    }
                    .padding()
                    HStack {
                        Text("Restart:")
                            .font(Font.custom("Helvetica Neue", size: 20.0))
                            .padding(7)
                            .foregroundColor(Color.black)
                            .padding(20)
                        Button {
                            CameraManager.shared.handleDeviceOrientationChange()
                            BufferManager.shared.resetBuffer()
                        } label: {
                            Text("Restart")
                                .font(Font.custom("Helvetica Neue", size: 20.0))
                                .padding(7)
                                .foregroundColor(Color.black)
                                .background(Color.yellow)
                                .cornerRadius(12)
                                .padding(12)
                        }
                    }
                    
                    Picker("Device", selection: $cameraManager.selectedDeviceUniqueID) {
                      ForEach(cameraManager.availableDevices, id: \.uniqueID) { dev in
                        Text(dev.localizedName).tag(dev.uniqueID)
                      }
                    }


                    // 1️⃣ Format picker (showing HDR, binning & FOV)
                    Picker("Format", selection: $cameraManager.selectedFormatIndex) {
                      ForEach(Array(cameraManager.availableFormats.enumerated()), id: \.offset) { idx, fmt in
                        let desc        = fmt.formatDescription
                        let dims        = CMVideoFormatDescriptionGetDimensions(desc)
                        let sizeLabel: String = {
                          switch (dims.width, dims.height) {
                          case (3840, 2160): return "4K"
                          case (_, 1080):    return "1080p"
                          case (_, 720):     return "720p"
                          default:           return "\(dims.width)x\(dims.height)"
                          }
                        }()

                        let maxFPS     = fmt.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                        let fpsLabel   = "\(Int(maxFPS))fps"

                        let minSh      = Int(CMTimeGetSeconds(fmt.minExposureDuration) * 100_000)
                        let shutterLabel = "\(minSh)s"

                        let flags      = [
                          fmt.isVideoHDRSupported ? "HDR" : "",
                          fmt.isVideoBinned       ? "Bin" : ""
                        ].filter { !$0.isEmpty }

                        let fov        = String(format: "%.1f°", fmt.videoFieldOfView)

                        let components = [sizeLabel, fpsLabel, shutterLabel] + flags + [fov]
                        let label      = components.joined(separator: " • ")

                        Text(label).tag(idx)
                      }
                    }
                    .pickerStyle(MenuPickerStyle())

                    // just below your Format picker…
                    Picker("Frame Rate", selection: $cameraManager.selectedFrameRate) {
                      ForEach(cameraManager.availableFrameRates, id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                      }
                    }
                    .pickerStyle(MenuPickerStyle())

                    // 2️⃣ Frame-rate picker
                    if !cameraManager.availableFrameRates.isEmpty {
                      Picker("FPS", selection: $cameraManager.selectedFrameRate) {
                        ForEach(cameraManager.availableFrameRates, id: \.self) { fps in
                          Text("\(Int(fps)) fps").tag(fps)
                        }
                      }
                      .pickerStyle(SegmentedPickerStyle())
                    }
                    HStack {
                        Text("Voice On:")
                            .font(Font.custom("Helvetica Neue", size: 20.0))
                            .padding(7)
                            .foregroundColor(Color.black)
                            .padding(20)
                        Toggle(isOn: $settings.voiceOn) {
                            Text(settings.voiceOn ? "Enabled" : "Disabled")
                                .font(Font.custom("Helvetica Neue", size: 20.0))
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .yellow))
                        .padding()
                    }
                    HStack {
                        Text("Show Pose:")
                            .font(Font.custom("Helvetica Neue", size: 20.0))
                            .padding(7)
                            .foregroundColor(Color.black)
                            .padding(20)
                        Toggle(isOn: $settings.showPose) {
                            Text(settings.showPose ? "Enabled" : "Disabled")
                                .font(Font.custom("Helvetica Neue", size: 20.0))
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .yellow))
                        .padding()
                    }
                    HStack {
                        Text("Resize Aspect Fill:")
                            .font(Font.custom("Helvetica Neue", size: 20.0))
                            .padding(7)
                            .foregroundColor(Color.black)
                            .padding(20)
                        Toggle(isOn: $settings.resizeAspectFill) {
                            Text(settings.resizeAspectFill ? "Enabled" : "Disabled")
                                .font(Font.custom("Helvetica Neue", size: 20.0))
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .yellow))
                        .padding()
                    }
                    HStack {
                        Text("Auto Show Replay:")
                            .font(Font.custom("Helvetica Neue", size: 20.0))
                            .padding(7)
                            .foregroundColor(Color.black)
                            .padding(20)
                        Toggle(isOn: $settings.autoShowReplay) {
                            Text(settings.autoShowReplay ? "Enabled" : "Disabled")
                                .font(Font.custom("Helvetica Neue", size: 20.0))
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .yellow))
                        .padding()
                    }
                    HStack {
                        Text("Auto Save Replay:")
                            .font(Font.custom("Helvetica Neue", size: 20.0))
                            .padding(7)
                            .foregroundColor(Color.black)
                            .padding(20)
                        Toggle(isOn: $settings.autoSaveReplay) {
                            Text(settings.autoSaveReplay ? "Enabled" : "Disabled")
                                .font(Font.custom("Helvetica Neue", size: 20.0))
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .yellow))
                        .padding()
                    }
                    
//                                    HStack {
//                                        Text("Video Orientation:")
//                                            .font(Font.custom("Helvetica Neue", size: 20.0))
//                                            .padding(7)
//                                            .foregroundColor(Color.black)
//                                            .padding(20)
//                                        Button {
//                                            // Cycle through orientations
//                                            switch cameraManager.previewLayerVideoOrientation {
//                                            case .portrait:
//                                                cameraManager.previewLayerVideoOrientation = .landscapeLeft
//                                            case .landscapeLeft:
//                                                cameraManager.previewLayerVideoOrientation = .landscapeRight
//                                            case .landscapeRight:
//                                                cameraManager.previewLayerVideoOrientation = .portraitUpsideDown
//                                            case .portraitUpsideDown:
//                                                cameraManager.previewLayerVideoOrientation = .portrait
//                                            @unknown default:
//                                                cameraManager.previewLayerVideoOrientation = .portrait
//                                            }
//                                        } label: {
//                                            Text(
//                                                cameraManager.previewLayerVideoOrientation == .portrait ? "Portrait" :
//                                                cameraManager.previewLayerVideoOrientation == .landscapeLeft ? "Landscape Left" :
//                                                cameraManager.previewLayerVideoOrientation == .landscapeRight ? "Landscape Right" :
//                                                "Portrait Upside Down"
//                                            )
//                                                .font(Font.custom("Helvetica Neue", size: 20.0))
//                                                .padding(7)
//                                                .foregroundColor(Color.black)
//                                                .background(Color.green)
//                                                .cornerRadius(12)
//                                                .padding(12)
//                                        }
//                                        Spacer()
//                                    }
//
//                                    HStack {
//                                        Text("Capture Orientation:")
//                                            .font(Font.custom("Helvetica Neue", size: 20.0))
//                                            .padding(7)
//                                            .foregroundColor(Color.black)
//                                            .padding(20)
//                                        Button {
//                                            // Cycle through orientations
//                                            switch cameraManager.captureVideoOrientation {
//                                            case .portrait:
//                                                cameraManager.captureVideoOrientation = .landscapeLeft
//                                            case .landscapeLeft:
//                                                cameraManager.captureVideoOrientation = .landscapeRight
//                                            case .landscapeRight:
//                                                cameraManager.captureVideoOrientation = .portraitUpsideDown
//                                            case .portraitUpsideDown:
//                                                cameraManager.captureVideoOrientation = .portrait
//                                            @unknown default:
//                                                cameraManager.captureVideoOrientation = .portrait
//                                            }
//                                        } label: {
//                                            Text(
//                                                cameraManager.captureVideoOrientation == .portrait ? "Portrait" :
//                                                cameraManager.captureVideoOrientation == .landscapeLeft ? "Landscape Left" :
//                                                cameraManager.captureVideoOrientation == .landscapeRight ? "Landscape Right" :
//                                                "Portrait Upside Down"
//                                            )
//                                                .font(Font.custom("Helvetica Neue", size: 20.0))
//                                                .padding(7)
//                                                .foregroundColor(Color.black)
//                                                .background(Color.green)
//                                                .cornerRadius(12)
//                                                .padding(12)
//                                        }
//                                        Spacer()
//                                    }
                    
                    
                    
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Files in Documents Folder:")
                            .font(Font.custom("Helvetica Neue", size: 20.0))
                            .bold()
                            .padding(10)
                        
                        ScrollView {
                            ForEach(fetchFiles(), id: \.self.name) { file in
                                HStack {
                                    Text(file.name)
                                        .font(Font.custom("Helvetica Neue", size: 16.0))
                                        .foregroundColor(.black)
                                    Spacer()
                                    Text(file.size)
                                        .font(Font.custom("Helvetica Neue", size: 16.0))
                                        .foregroundColor(.gray)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 5)
                            }
                        }
                        .frame(maxHeight: 200)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                        .padding(10)
                    }
                }
                
                
            }.padding()
            
            /*
            Slider(
                value: $timeBeforeShot,
                in: 1...15,
                step: 1
            ).position(x: 500, y: 100)*/
            //\Text("Seconds Before Shot \(timeBeforeShot)").position(x: 500, y: 100)
        }
    }
}
func fetchFiles() -> [FileInfo] {
    let fileManager = FileManager.default
    let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    var files: [FileInfo] = []
    
    do {
        let fileURLs = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey], options: [])
        let sortedFileURLs = fileURLs.sorted {
            let date1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let date2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return date1 > date2
        }

        for fileURL in sortedFileURLs {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            let fileSize = attributes[.size] as? Int ?? 0
            files.append(FileInfo(name: fileURL.lastPathComponent, size: "\(fileSize / 1024) KB"))
        }

    } catch {
        print("Error fetching files: \(error)")
    }
    
    return files
}

struct FileInfo: Hashable {
    let name: String
    let size: String
}
