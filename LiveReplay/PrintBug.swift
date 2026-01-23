//
//  PrintBug.swift
//  LiveReplay
//
//  Created by Albert Soong on 3/12/25.
//

import Foundation

enum BugCategory: String {
    case bugDelayObserver
    case bugTimeObserver
    case bugPlayerItemObserver
    case bugForwardRewind
    case bugSmoothlyJump
    case bugJumpToPlayingTime
    case bugAssetWriter
    case bugPercentagePlayed
    case bugBuffer
    case bugPlayerQueue
    case bugResourceLoader
    case bugTimeElapsed
    case bugScrolling
    case bugReload
    case bugSnapshot
    case bugTimingBuffer
}

struct BugSettings {
    static var isLoggingEnabled: Bool = false
    static var showCategories: Bool = true
    static var showFileAndLineNumbers: Bool = false
    static var showCategory: [BugCategory: Bool] = [
        .bugDelayObserver: false,
        .bugTimeObserver: false,
        .bugPlayerItemObserver: true,//
        .bugForwardRewind: false,
        .bugSmoothlyJump: true,//
        .bugJumpToPlayingTime: true,//
        .bugAssetWriter: false,//
        .bugPercentagePlayed: false,
        .bugBuffer: true    ,//
        .bugPlayerQueue: true,//
        .bugResourceLoader: false,
        .bugTimeElapsed: false,
        .bugScrolling: true,
        .bugReload: true,//
        .bugSnapshot: true,
        .bugTimingBuffer: true
    ]
}

func printBug(
    _ category: BugCategory,
    _ items: Any...,
    separator: String = " ",
    terminator: String = "\n",
    file: String = #file,
    line: Int = #line
) {
    guard BugSettings.isLoggingEnabled, BugSettings.showCategory[category] == true else { return }

    var logComponents: [String] = []

    if BugSettings.showCategories {
        logComponents.append("[\(category.rawValue)]")
    }

    if BugSettings.showFileAndLineNumbers {
        let fileName = (file as NSString).lastPathComponent
        logComponents.append("[\(fileName):\(line)]")
    }

    let output = items.map { "\($0)" }.joined(separator: separator)
    logComponents.append(output)

    print(logComponents.joined(separator: " "), terminator: terminator)
}

func doBug(_ category: BugCategory) -> Bool {
    if BugSettings.isLoggingEnabled && BugSettings.showCategory[category] == true {
        return true
    } else {
        return false
    }
}
