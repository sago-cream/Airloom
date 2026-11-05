import AppKit
import AVFoundation
import Darwin

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let settings = try WallpaperSettings.load()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                      styleMask: .borderless, backing: .buffered, defer: false)
window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
window.ignoresMouseEvents = true
window.isOpaque = false
window.backgroundColor = .clear
window.isReleasedWhenClosed = false
let video = LoopingVideoView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
video.setPlaceholder(LoopingVideoView.placeholder(from: URL(fileURLWithPath: settings.posterPath ?? WallpaperSettings.posterURL.path)))
window.contentView = video
window.orderBack(nil)

func footprintMiB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    return Double(info.phys_footprint) / 1_048_576
}

Task { @MainActor in
    do {
        let asset = AVURLAsset(url: URL(fileURLWithPath: settings.mediaPath))
        let duration = try await asset.load(.duration).seconds
        var nextPosition = 0.0
        var samples: [[String: Double]] = []
        for cycle in 1...20 {
            video.setPlaying(false)
            video.load(url: URL(fileURLWithPath: settings.mediaPath), resumeAt: nextPosition)
            video.setPlaying(true)
            let deadline = Date().addingTimeInterval(5)
            while video.player?.currentItem?.status != .readyToPlay || video.player?.rate != 1 {
                guard Date() < deadline else { fatalError("Decoder did not become ready") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let restored = video.player!.currentTime().seconds
            let distance = min(abs(restored - nextPosition), abs(duration - abs(restored - nextPosition)))
            precondition(distance < 0.5, "Resume did not restore the saved position")
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let activeFootprint = footprintMiB()
            nextPosition = video.player!.currentTime().seconds.truncatingRemainder(dividingBy: duration)
            video.unload(preserveFrame: true)
            precondition(video.player == nil && video.layer?.sublayers?.isEmpty != false,
                         "Playback resources remained attached after teardown")
            try await Task.sleep(nanoseconds: 600_000_000)
            precondition(video.hasPlaceholder && !video.stillPreparing, "Still image was not ready after decoder teardown")
            malloc_zone_pressure_relief(nil, 0)
            samples.append(["cycle": Double(cycle), "active_footprint_mib": activeFootprint,
                            "paused_footprint_mib": footprintMiB()])
        }
        let first = samples.prefix(5).reduce(0) { $0 + $1["paused_footprint_mib"]! } / 5
        let last = samples.suffix(5).reduce(0) { $0 + $1["paused_footprint_mib"]! } / 5
        let result: [String: Any] = ["cycles": samples.count, "initial_paused_mean_mib": first,
            "final_paused_mean_mib": last, "growth_mib": last - first, "samples": samples,
            "limitation": "Component lifecycle test; not an app-wide or multi-day memory benchmark"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "Benchmarks/decoder-memory-lifecycle.json"), options: .atomic)
        precondition(last - first < 8 && last < 64, "Decoder footprint grew beyond the test budget")
        print("Verified 20 real decoder load/seek/play/unload cycles; paused footprint growth \(String(format: "%.2f", last - first)) MiB")
        video.unload()
        precondition(!video.hasPlaceholder)
        window.close()
        app.terminate(nil)
    } catch {
        fputs("Memory lifecycle test failed: \(error)\n", stderr)
        exit(1)
    }
}
app.run()
