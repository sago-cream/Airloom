import AppKit
import AVFoundation

enum LockScreenError: LocalizedError {
    case requiresTahoe, downloadAerial, invalidStore
    var errorDescription: String? {
        switch self {
        case .requiresTahoe: return "Animated lock-screen backgrounds require macOS 26 or later."
        case .downloadAerial: return "Download one aerial in System Settings → Wallpaper first, then enable the animated lock screen again."
        case .invalidStore: return "The macOS wallpaper configuration could not be read. Your wallpaper has not been changed."
        }
    }
}

struct LockScreenBackup: Codable {
    var slotID: String
    var previousModule: Data?
    var mediaPath: String
}

enum LockScreenInstaller {
    static let baseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper")
    static let storeURL = baseURL.appendingPathComponent("Store/Index.plist")
    static let backupURL = WallpaperSettings.supportURL.appendingPathComponent("Backups/LockScreen")
    static let stateURL = WallpaperSettings.supportURL.appendingPathComponent("lock-screen.json")
    static let targetDuration: Double = 600

    static func state() -> LockScreenBackup? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(LockScreenBackup.self, from: data)
    }

    static func install(settings: WallpaperSettings) async throws -> String {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { throw LockScreenError.requiresTahoe }
        let fm = FileManager.default
        let videos = baseURL.appendingPathComponent("aerials/videos")
        let knownIDs: Set<String> = try autoreleasepool {
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: baseURL.appendingPathComponent("aerials/manifest/entries.json"))) as? [String: Any]
            return Set((manifest?["assets"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        }
        let existing = state()
        let slots = try fm.contentsOfDirectory(at: videos, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mov" && knownIDs.contains($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let slot = slots.first(where: { $0.deletingPathExtension().lastPathComponent == existing?.slotID }) ?? slots.first else {
            throw LockScreenError.downloadAerial
        }
        let slotID = slot.deletingPathExtension().lastPathComponent
        guard UUID(uuidString: slotID) != nil else { throw LockScreenError.downloadAerial }
        let staged = try await exportMovie(from: URL(fileURLWithPath: settings.mediaPath))
        defer { try? fm.removeItem(at: staged) }
        try fm.createDirectory(at: backupURL, withIntermediateDirectories: true)
        let movieBackup = backupURL.appendingPathComponent("\(slotID).mov")
        if !fm.fileExists(atPath: movieBackup.path) { try fm.copyItem(at: slot, to: movieBackup) }
        let originalIndex = try Data(contentsOf: storeURL)
        let indexBackup = backupURL.appendingPathComponent("Index.plist")
        if !fm.fileExists(atPath: indexBackup.path) { try originalIndex.write(to: indexBackup, options: .atomic) }
        guard let store = try PropertyListSerialization.propertyList(from: originalIndex, format: nil) as? [String: Any] else {
            throw LockScreenError.invalidStore
        }
        let selected = try AerialConfiguration.selecting(slotID, in: store)
        let selectedData = try PropertyListSerialization.data(fromPropertyList: selected, format: .binary, options: 0)
        let module = CFPreferencesCopyValue("moduleDict" as CFString, "com.apple.screensaver" as CFString,
                                            kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        let previousModule = existing?.previousModule ?? module.flatMap {
            try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
        }
        // Keep a rollback copy of the currently installed movie until both writes succeed.
        let rollback = backupURL.appendingPathComponent("current-\(UUID().uuidString).mov")
        try fm.copyItem(at: slot, to: rollback)
        defer { try? fm.removeItem(at: rollback) }
        do {
            _ = try fm.replaceItemAt(slot, withItemAt: staged)
            try selectedData.write(to: storeURL, options: .atomic)
            let record = LockScreenBackup(slotID: slotID, previousModule: previousModule, mediaPath: settings.mediaPath)
            try JSONEncoder().encode(record).write(to: stateURL, options: .atomic)
        } catch {
            _ = try? fm.replaceItemAt(slot, withItemAt: rollback)
            try? originalIndex.write(to: storeURL, options: .atomic)
            throw error
        }
        let aerialModule: [String: Any] = ["moduleName": "WallpaperAerialsExtension",
            "path": "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex", "type": 0]
        CFPreferencesSetValue("moduleDict" as CFString, aerialModule as CFDictionary, "com.apple.screensaver" as CFString,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize("com.apple.screensaver" as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return slotID
    }

    private static func exportMovie(from source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        defer { asset.cancelLoading() }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoImportError.noVideo }
        let range = try await track.load(.timeRange)
        guard range.duration.isNumeric, range.duration.seconds >= 0.1 else { throw VideoImportError.noVideo }
        let composition = AVMutableComposition()
        guard let destination = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoImportError.exportUnavailable
        }
        let repeats = max(1, Int(ceil(targetDuration / range.duration.seconds)))
        try autoreleasepool {
            for index in 0..<repeats {
                try destination.insertTimeRange(range, of: track, at: CMTimeMultiply(range.duration, multiplier: Int32(index)))
            }
        }
        destination.preferredTransform = try await track.load(.preferredTransform)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoImportError.exportUnavailable
        }
        export.shouldOptimizeForNetworkUse = true
        let output = WallpaperSettings.supportURL.appendingPathComponent("aerial-\(UUID().uuidString).mov")
        do {
            try await export.export(to: output, as: .mov)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    static func restore() throws {
        guard let state = state() else { return }
        guard UUID(uuidString: state.slotID) != nil else { throw LockScreenError.invalidStore }
        let movie = baseURL.appendingPathComponent("aerials/videos/\(state.slotID).mov")
        let originalMovie = backupURL.appendingPathComponent("\(state.slotID).mov")
        let temp = movie.deletingLastPathComponent().appendingPathComponent("restore-\(UUID().uuidString).mov")
        try FileManager.default.copyItem(at: originalMovie, to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let previous = try PropertyListSerialization.propertyList(from: Data(contentsOf: backupURL.appendingPathComponent("Index.plist")), format: nil) as? [String: Any],
              let current = try PropertyListSerialization.propertyList(from: Data(contentsOf: storeURL), format: nil) as? [String: Any]
        else { throw LockScreenError.invalidStore }
        let restored = AerialConfiguration.restoring(previous, in: current, slotID: state.slotID)
        let data = try PropertyListSerialization.data(fromPropertyList: restored, format: .binary, options: 0)
        _ = try FileManager.default.replaceItemAt(movie, withItemAt: temp)
        try data.write(to: storeURL, options: .atomic)
        if let moduleData = state.previousModule,
           let module = try? PropertyListSerialization.propertyList(from: moduleData, format: nil) {
            CFPreferencesSetValue("moduleDict" as CFString, module as CFPropertyList, "com.apple.screensaver" as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSynchronize("com.apple.screensaver" as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        try FileManager.default.removeItem(at: stateURL)
    }

    static func reload(includeAgent: Bool) {
        for name in includeAgent ? ["WallpaperAerialsExtension", "WallpaperAgent"] : ["WallpaperAerialsExtension"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = ["-u", NSUserName(), name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch { NSLog("Torii: unable to refresh %@: %@", name, error.localizedDescription) }
        }
    }
}
