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
        video.load(url: URL(fileURLWithPath: settings.mediaPath), resumeAt: max(0, duration - 5))
        @MainActor func waitUntilReady() async throws {
            let deadline = Date().addingTimeInterval(5)
            while !video.prepared || !video.presented || video.player?.rate != 1 {
                precondition(Date() < deadline, "Player did not become ready")
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try await waitUntilReady()
        let identity = ObjectIdentifier(video.player!)
        var samples: [[String: Double]] = []
        for cycle in 1...20 {
            video.setPlaying(true)
            try await Task.sleep(nanoseconds: 400_000_000)
            let activeFootprint = footprintMiB()
            video.setPlaying(false)
            let pausedAt = video.player!.currentTime().seconds
            try await Task.sleep(nanoseconds: 300_000_000)
            let delta = abs(video.player!.currentTime().seconds - pausedAt)
            precondition(min(delta, abs(duration - delta)) < 0.03, "Paused clock kept advancing")
            precondition(ObjectIdentifier(video.player!) == identity && video.loadGeneration == 1,
                         "Pause/resume created a replacement decoder")
            precondition(video.presented && !video.hasPlaceholder, "Paused playback exposed a poster")
            precondition(video.player!.items().count <= 3, "Loop queue grew")
            malloc_zone_pressure_relief(nil, 0)
            samples.append(["cycle": Double(cycle), "active_footprint_mib": activeFootprint,
                            "paused_footprint_mib": footprintMiB()])
        }
        let first = samples.prefix(5).reduce(0) { $0 + $1["paused_footprint_mib"]! } / 5
        let last = samples.suffix(5).reduce(0) { $0 + $1["paused_footprint_mib"]! } / 5
        for _ in 0..<5 {
            weak var previous = video.player
            video.unload()
            precondition(video.player == nil && video.layer?.sublayers?.isEmpty != false)
            try await Task.sleep(nanoseconds: 250_000_000)
            precondition(previous == nil, "Replacement retained the old player")
            previous = nil
            video.load(url: URL(fileURLWithPath: settings.mediaPath))
            video.setPlaying(true)
            try await waitUntilReady()
        }
        video.unload()
        let result: [String: Any] = ["cycles": samples.count, "replacement_cycles": 5,
            "mode": "One retained player across play/pause cycles",
            "initial_paused_mean_mib": first, "final_paused_mean_mib": last,
            "growth_mib": last - first, "samples": samples,
            "limitation": "Component lifecycle test; not an app-wide or multi-day memory benchmark"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "Benchmarks/decoder-memory-lifecycle.json"), options: .atomic)
        precondition(last - first < 8 && last < 96, "Retained-player footprint exceeded the test budget")
        print("Verified 20 warm play/pause cycles and 5 complete player replacements")
        window.close()
        app.terminate(nil)
    } catch {
        fputs("Memory lifecycle test failed: \(error)\n", stderr)
        exit(1)
    }
}
app.run()
