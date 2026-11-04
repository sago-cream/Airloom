import AppKit
import AVFoundation

enum VideoImportError: LocalizedError {
    case noVideo, exportUnavailable, screenSaverMissing, signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: return "Choose an MP4 containing a playable video track."
        case .exportUnavailable: return "This video's codec cannot be copied into an MP4. Export it as H.264 or HEVC first."
        case .screenSaverMissing: return "The Torii screen saver is missing. Reinstall Torii, then import again."
        case .signingFailed(let detail): return "Could not prepare the screen saver: \(detail)"
        }
    }
}

struct PreparedVideo {
    let directory: URL
    let videoURL: URL
    let posterURL: URL
    let screenSaverURL: URL
    let sourceURL: URL
}

enum VideoImporter {
    static var installedSaverURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Screen Savers/Torii.saver")
    }

    static func prepare(source: URL) async throws -> PreparedVideo {
        guard source.pathExtension.lowercased() == "mp4" else { throw VideoImportError.noVideo }
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isPlayable),
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoImportError.noVideo
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else { throw VideoImportError.noVideo }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw VideoImportError.exportUnavailable }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        videoTrack.preferredTransform = try await track.load(.preferredTransform)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        else { throw VideoImportError.exportUnavailable }
        let directory = WallpaperSettings.supportURL.appendingPathComponent("Media/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let videoURL = directory.appendingPathComponent("Wallpaper.mp4")
            try await exporter.export(to: videoURL, as: .mp4)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1920, height: 1920)
            let generated = try await generator.image(at: .zero)
            let bitmap = NSBitmapImageRep(cgImage: generated.image)
            guard let poster = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            else { throw VideoImportError.noVideo }
            let posterURL = directory.appendingPathComponent("Poster.jpg")
            try poster.write(to: posterURL, options: .atomic)
            let stagedSaver = directory.appendingPathComponent("Torii.saver")
            try await Task.detached(priority: .userInitiated) {
                guard FileManager.default.fileExists(atPath: installedSaverURL.path) else {
                    throw VideoImportError.screenSaverMissing
                }
                try FileManager.default.copyItem(at: installedSaverURL, to: stagedSaver)
                let saverMedia = stagedSaver.appendingPathComponent("Contents/Resources/Wallpaper.mp4")
                if FileManager.default.fileExists(atPath: saverMedia.path) { try FileManager.default.removeItem(at: saverMedia) }
                try FileManager.default.copyItem(at: videoURL, to: saverMedia)
                let signing = Process()
                let errors = Pipe()
                signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                signing.arguments = ["--force", "--sign", "-", "--timestamp=none", stagedSaver.path]
                signing.standardError = errors
                signing.standardOutput = FileHandle.nullDevice
                try signing.run()
                let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                signing.waitUntilExit()
                guard signing.terminationStatus == 0 else { throw VideoImportError.signingFailed(detail) }
            }.value
            return PreparedVideo(directory: directory, videoURL: videoURL, posterURL: posterURL,
                                 screenSaverURL: stagedSaver, sourceURL: source)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func activate(_ prepared: PreparedVideo, previous: WallpaperSettings) throws -> WallpaperSettings {
        var settings = previous
        settings.sourcePath = prepared.sourceURL.path
        settings.mediaPath = prepared.videoURL.path
        settings.posterPath = prepared.posterURL.path
        settings.title = prepared.sourceURL.deletingPathExtension().lastPathComponent
        try settings.save()
        do {
            _ = try FileManager.default.replaceItemAt(installedSaverURL, withItemAt: prepared.screenSaverURL)
        } catch {
            try? previous.save()
            throw error
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.hsi.Torii.wallpaperChanged"), object: nil, userInfo: nil, deliverImmediately: true
        )
        return settings
    }

    static func removePreviousMedia(_ previous: WallpaperSettings, keeping settings: WallpaperSettings) {
        let oldDirectory = URL(fileURLWithPath: previous.mediaPath).deletingLastPathComponent()
        let mediaRoot = WallpaperSettings.supportURL.appendingPathComponent("Media").standardizedFileURL
        // Delete only an app-generated UUID directory; never a user's source video.
        guard previous.mediaPath != settings.mediaPath,
              oldDirectory.deletingLastPathComponent().standardizedFileURL == mediaRoot,
              UUID(uuidString: oldDirectory.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: oldDirectory)
    }
}
