import AppKit
import AVFoundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let settingsBefore = try Data(contentsOf: WallpaperSettings.settingsURL)

Task { @MainActor in
    do {
        do {
            _ = try await VideoImporter.prepare(source: URL(fileURLWithPath: "/invalid/wallpaper.jpeg"))
            fatalError("A non-MP4 must be rejected")
        } catch VideoImportError.noVideo {}
        let prepared = try await VideoImporter.prepare(source: source)
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let input = AVURLAsset(url: source)
        let output = AVURLAsset(url: prepared.videoURL)
        let inputVideo = try await input.loadTracks(withMediaType: .video).first!
        let outputTracks = try await output.load(.tracks)
        require(outputTracks.count == 1, "Import must retain exactly one video track")
        let outputVideo = try await output.loadTracks(withMediaType: .video).first!
        let inputSize = try await inputVideo.load(.naturalSize)
        let outputSize = try await outputVideo.load(.naturalSize)
        require(inputSize == outputSize, "Import must preserve resolution")
        let inputRate = try await inputVideo.load(.nominalFrameRate)
        let outputRate = try await outputVideo.load(.nominalFrameRate)
        require(inputRate == outputRate, "Import must preserve frame rate")
        let inputTransform = try await inputVideo.load(.preferredTransform)
        let outputTransform = try await outputVideo.load(.preferredTransform)
        require(inputTransform == outputTransform, "Import must preserve rotation")
        let inputDuration = try await input.load(.duration).seconds
        let outputDuration = try await output.load(.duration).seconds
        require(abs(inputDuration - outputDuration) < 0.1, "Import must preserve duration")
        let settingsAfter = try Data(contentsOf: WallpaperSettings.settingsURL)
        require(settingsAfter == settingsBefore,
                "Preparation must not change the active wallpaper")
        print("Native import passed: MP4 validation, audio removal, dimensions, frame rate, rotation, duration, isolated staging")
        exit(0)
    } catch {
        fputs("Import test failed: \(error)\n", stderr)
        exit(1)
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fatalError("Import test timed out") }
RunLoop.main.run()
