//
//  InMemoryMP4ResourceLoader.swift
//  LiveReplay
//
//  Created by Albert Soong on 2/4/25.
//
//  PURPOSE:
//  This file provides a custom AVAssetResourceLoaderDelegate that allows AVFoundation to load
//  MP4 video data directly from memory (Data) instead of requiring a file on disk. This is
//  essential for applications that generate video segments in memory or receive video data
//  over the network and want to play it immediately without writing to disk first.
//
//  USAGE:
//  Instead of: AVURLAsset(url: fileURL)
//  Use:        AVURLAsset(mp4Data: data)
//
//  The resulting AVURLAsset can be used exactly like a file-based asset with AVPlayer,
//  AVPlayerItem, etc. The resource loader intercepts all file I/O requests and serves
//  data from the in-memory Data object.
//
//  DESIGN DECISIONS & AI NOTES:
//  1. Uses custom URL scheme "inmemory-mp4://" - AVFoundation treats this as a file URL
//     and calls our resourceLoader delegate to handle requests.
//
//  2. currentOffset handling (CRITICAL): AVFoundation requests data incrementally.
//     We MUST respect dataRequest.currentOffset, not just requestedOffset. If we
//     always start from requestedOffset, we'll send duplicate data and break playback.
//     Rule: start = max(requestedOffset, currentOffset)
//
//  3. EOF clamping: Instead of erroring when a request goes past end-of-file, we clamp
//     to EOF and send what we have. This is more robust and matches how file-based
//     loading works. Rule: end = min(requestedEnd, EOF)
//
//  4. finishLoading() must be called exactly once per request, either:
//     - finishLoading() for success
//     - finishLoading(with: error) for failure
//     Both content info and data requests can be in the same loadingRequest, so we
//     handle both and finish once at the end.
//
//  5. Memory retention: The loader is retained via associated object on the AVURLAsset.
//     This prevents deallocation during playback. The loader retains the mp4Data.
//
//  6. Thread safety: All requests come on the delegate queue (userInitiated). The mp4Data
//     is immutable (let), so no synchronization needed. subdata() creates a copy.
//
//  POTENTIAL IMPROVEMENTS (for future consideration):
//  - Streaming support: Currently assumes all data is available. Could extend to support
//    incremental data arrival by tracking what's been sent and only finishing when complete.
//  - Caching: For very large files, could implement range caching to avoid repeated subdata()
//    calls for the same ranges.
//  - Error recovery: Could add retry logic for transient errors.
//
//  EDGE CASES HANDLED:
//  - Empty data: Validated in init() with fatalError (should never happen in production)
//  - Out-of-bounds requests: Returns detailed error with all relevant offsets
//  - Already-satisfied requests: Returns nil (success) without sending data
//  - Requests past EOF: Clamps to EOF and sends available data
//  - Both info and data requests in same loadingRequest: Handles both sequentially
//
//  WHEN MODIFYING THIS FILE:
//  - Always test with actual video playback, not just unit tests
//  - Verify currentOffset handling - this is the most common source of bugs
//  - Ensure finishLoading() is called exactly once per request
//  - Test with various video formats, sizes, and seeking scenarios
//  - Consider memory pressure with large files (current implementation keeps full Data in memory)
//

import AVFoundation
import ObjectiveC

/// Custom resource loader that serves MP4 data from memory instead of disk.
///
/// This class implements AVAssetResourceLoaderDelegate to intercept AVFoundation's file
/// loading requests and serve data from an in-memory Data object. It handles both content
/// information requests (metadata) and data requests (actual bytes).
///
/// **Thread Safety**: All delegate methods are called on the queue specified in
/// `setDelegate(_:queue:)` (userInitiated queue). The mp4Data is immutable, so no
/// synchronization is required.
///
/// **Memory Management**: The loader is retained by the AVURLAsset via associated object.
/// The loader retains the mp4Data, creating a retain cycle that prevents deallocation
/// during playback. This is intentional and correct.
final class InMemoryMP4ResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    /// The complete MP4 file data stored in memory.
    /// This is immutable and thread-safe to read from multiple threads.
    private let mp4Data: Data

    /// Associated object key for retaining the loader on the AVURLAsset.
    /// Must be fileprivate (not private) so the AVURLAsset extension can access it.
    /// This is a standard pattern for associated object keys in Swift.
    fileprivate static var associatedObjectKey: UInt8 = 0

    /// Initializes the resource loader with MP4 data.
    ///
    /// - Parameter mp4Data: The complete MP4 file data. Must not be empty.
    /// - Important: This will fatalError if mp4Data is empty. In production, validate
    ///   data before creating the loader.
    init(mp4Data: Data) {
        guard !mp4Data.isEmpty else {
            fatalError("InMemoryMP4ResourceLoader: mp4Data cannot be empty")
        }
        self.mp4Data = mp4Data
        super.init()
        printBug(.bugResourceLoader, "✅ [ResourceLoader] Initialized with \(mp4Data.count) bytes")
    }

    deinit {
        printBug(.bugResourceLoader, "❌ [ResourceLoader] Deallocated")
    }

    /// Main delegate method called by AVFoundation when it needs to load a resource.
    ///
    /// This method handles two types of requests:
    /// 1. **Content Information Request**: Provides metadata (file size, MIME type, byte-range support)
    /// 2. **Data Request**: Provides actual MP4 bytes for a specific byte range
    ///
    /// Both request types can be present in the same `loadingRequest`. We handle both
    /// sequentially and then call `finishLoading()` once at the end.
    ///
    /// - Parameters:
    ///   - resourceLoader: The AVAssetResourceLoader that received the request
    ///   - loadingRequest: The request containing either content info, data, or both
    /// - Returns: `true` if we handled the request, `false` if we cannot handle it
    ///   (e.g., wrong URL scheme). Returning `false` tells AVFoundation to try other
    ///   resource loaders or fall back to file-based loading.
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {

        // Validate URL exists
        guard let url = loadingRequest.request.url else {
            printBug(.bugResourceLoader, "❌ [ResourceLoader] Request URL is nil")
            return false
        }

        // Only handle our custom URL scheme
        guard url.scheme == "inmemory-mp4" else {
            printBug(.bugResourceLoader, "❌ [ResourceLoader] Unsupported scheme: \(url.scheme ?? "nil")")
            return false
        }

        // Track if we handled any request and if there was an error
        var handledAnything = false
        var error: Error?

        // Handle Content Information Request (metadata)
        // This provides AVFoundation with file size, MIME type, and byte-range support.
        // This can be requested alone or together with a data request.
        if let info = loadingRequest.contentInformationRequest {
            handledAnything = true
            fillContentInfo(info)
        }

        // Handle Data Request (actual bytes)
        // AVFoundation requests data in byte ranges. We must respect currentOffset
        // to handle incremental requests correctly.
        if let data = loadingRequest.dataRequest {
            handledAnything = true
            error = serveData(data)
        }

        // If we didn't handle anything, return false (let AVFoundation try other loaders)
        guard handledAnything else {
            printBug(.bugResourceLoader, "⚠️ [ResourceLoader] No contentInformationRequest or dataRequest")
            return false
        }

        // Finish the loading request exactly once
        // If data request failed, finish with error. Otherwise finish successfully.
        // Note: We always finish, even if only content info was requested.
        if let error {
            loadingRequest.finishLoading(with: error)
        } else {
            loadingRequest.finishLoading()
        }

        return true
    }

    // MARK: - Helpers

    /// Fills the content information request with MP4 metadata.
    ///
    /// This method sets:
    /// - `contentType`: MP4 MIME type
    /// - `contentLength`: Total size of the MP4 data in bytes
    /// - `isByteRangeAccessSupported`: `true` (we support partial byte range requests)
    ///
    /// - Parameter info: The content information request to fill
    /// - Note: This method cannot fail - it's just setting properties. If mp4Data were
    ///   invalid, we'd discover that during data requests, not here.
    private func fillContentInfo(_ info: AVAssetResourceLoadingContentInformationRequest) {
        printBug(.bugResourceLoader, "ℹ️ [ResourceLoader] Handling content information request")
        
        info.contentType = AVFileType.mp4.rawValue
        info.contentLength = Int64(mp4Data.count)
        info.isByteRangeAccessSupported = true
        
        printBug(.bugResourceLoader, "📏 [ResourceLoader] Content length: \(mp4Data.count) bytes")
    }

    /// Serves the requested byte range from mp4Data.
    ///
    /// **CRITICAL: currentOffset handling**
    /// AVFoundation requests data incrementally. The `currentOffset` property tells us
    /// where AVFoundation thinks the next bytes should come from. We MUST use this,
    /// not just `requestedOffset`. If we always start from `requestedOffset`, we'll send
    /// duplicate data and break playback.
    ///
    /// **EOF Clamping**
    /// If a request goes past the end of the file, we clamp to EOF and send what we have.
    /// This is more robust than erroring and matches file-based behavior.
    ///
    /// **Edge Cases Handled:**
    /// - Invalid offset (negative or past EOF): Returns error with detailed info
    /// - Already satisfied request (currentOffset >= requestedEnd): Returns nil (success)
    /// - Request past EOF: Clamps to EOF, sends available data, returns nil (success)
    ///
    /// - Parameter dataRequest: The data request containing offset and length
    /// - Returns: `nil` on success, `Error` if the request is invalid (out of bounds)
    /// - Note: Even if we send partial data (due to EOF clamping), we return `nil`
    ///   (success). AVFoundation will handle the partial data correctly.
    private func serveData(_ dataRequest: AVAssetResourceLoadingDataRequest) -> Error? {
        // Extract request parameters
        let reqStart = dataRequest.requestedOffset      // Where the request wants to start
        let reqEnd = reqStart + Int64(dataRequest.requestedLength) // Exclusive end
        let cur = dataRequest.currentOffset            // Where AVFoundation expects next bytes

        // CRITICAL: Start from currentOffset, not requestedOffset
        // AVFoundation may have already received some data and is requesting more.
        // If we always start from requestedOffset, we'll send duplicate data.
        let start64 = max(reqStart, cur)

        // Clamp end to EOF (don't error if request goes past end)
        let eof64 = Int64(mp4Data.count)
        let end64 = min(reqEnd, eof64)

        printBug(.bugResourceLoader, "📡 [ResourceLoader] Requested byte range: \(reqStart) to \(reqEnd), current: \(cur)")

        // Validate start offset (must be non-negative and not past EOF)
        guard start64 >= 0, start64 <= eof64 else {
            return NSError(
                domain: "InMemoryMP4",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Offset out of bounds",
                    "requestedOffset": reqStart,
                    "requestedLength": dataRequest.requestedLength,
                    "currentOffset": cur,
                    "dataLength": mp4Data.count
                ]
            )
        }

        // Check if there's actually data to send
        // This can happen if:
        // 1. The request was already satisfied (currentOffset >= requestedEnd)
        // 2. We're at EOF (start64 >= eof64)
        guard end64 > start64 else {
            printBug(.bugResourceLoader, "📡 [ResourceLoader] No data to send (already satisfied or at EOF)")
            return nil // Success - nothing to send
        }

        // Convert to Int for subdata() (safe because we've validated bounds)
        let start = Int(start64)
        let end = Int(end64)

        // Extract the requested byte range and send it
        // subdata() creates a copy, which is safe for concurrent access
        let requestedData = mp4Data.subdata(in: start..<end)
        
        printBug(.bugResourceLoader, "📤 [ResourceLoader] Sending \(requestedData.count) bytes")
        dataRequest.respond(with: requestedData)
        
        printBug(.bugResourceLoader, "✅ [ResourceLoader] Successfully handled data request")
        return nil // Success
    }
}

// MARK: - AVURLAsset Extension

extension AVURLAsset {
    /// Creates an AVURLAsset that loads MP4 data from memory instead of disk.
    ///
    /// This convenience initializer creates an AVURLAsset configured to load MP4 data
    /// directly from a Data object in memory, without requiring a file on disk.
    ///
    /// **Usage Example:**
    /// ```swift
    /// let mp4Data = // ... your MP4 data
    /// guard let asset = AVURLAsset(mp4Data: mp4Data) else {
    ///     // Handle initialization failure
    ///     return
    /// }
    /// let playerItem = AVPlayerItem(asset: asset)
    /// let player = AVPlayer(playerItem: playerItem)
    /// player.play()
    /// ```
    ///
    /// **How It Works:**
    /// 1. Creates a unique fake URL with scheme "inmemory-mp4://"
    /// 2. Initializes AVURLAsset with this URL
    /// 3. Creates an InMemoryMP4ResourceLoader with the data
    /// 4. Sets the loader as the resourceLoader delegate
    /// 5. Retains the loader via associated object (prevents deallocation)
    ///
    /// **Memory Management:**
    /// The loader is retained by the AVURLAsset via associated object. The loader
    /// retains the mp4Data. This creates a retain cycle that prevents deallocation
    /// during playback, which is intentional and correct. When the AVURLAsset is
    /// deallocated, the loader and data will be released.
    ///
    /// **Thread Safety:**
    /// The resource loader delegate methods are called on a background queue
    /// (userInitiated QoS). The mp4Data is immutable, so no synchronization is needed.
    ///
    /// - Parameter mp4Data: The complete MP4 file data. Must not be empty.
    /// - Returns: An AVURLAsset configured to load from memory, or `nil` if initialization
    ///   fails (empty data or URL creation failure).
    /// - Important: The returned AVURLAsset can be used exactly like a file-based asset.
    ///   All AVFoundation APIs work the same way. The resource loading is transparent.
    convenience init?(mp4Data: Data) {
        // Validate data is not empty
        guard !mp4Data.isEmpty else {
            printBug(.bugResourceLoader, "❌ [AVURLAsset] Cannot create asset from empty data")
            return nil
        }

        // Generate unique URL for this asset
        // Each asset needs a unique URL so AVFoundation can distinguish between them
        let uniqueID = UUID().uuidString
        guard let url = URL(string: "inmemory-mp4://video-\(uniqueID)") else {
            printBug(.bugResourceLoader, "❌ [AVURLAsset] Failed to create URL")
            return nil
        }

        printBug(.bugResourceLoader, "🚀 [AVURLAsset] Creating asset with URL: \(url)")

        // Initialize AVURLAsset with the fake URL
        // AVFoundation will call our resource loader when it tries to load this URL
        self.init(url: url)

        // Create the resource loader with the data
        let loader = InMemoryMP4ResourceLoader(mp4Data: mp4Data)
        
        // Set the loader as the delegate on a background queue
        // All delegate callbacks will happen on this queue
        self.resourceLoader.setDelegate(loader, queue: DispatchQueue.global(qos: .userInitiated))

        // Retain the loader via associated object
        // This prevents the loader (and thus mp4Data) from being deallocated during playback
        // The loader will be released when the AVURLAsset is deallocated
        objc_setAssociatedObject(
            self,
            &InMemoryMP4ResourceLoader.associatedObjectKey,
            loader,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        printBug(.bugResourceLoader, "✅ [AVURLAsset] Initialized in-memory asset: \(url)")
    }
}
