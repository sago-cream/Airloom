import AppKit
import AVFoundation

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let sample = """
FIQCA(0x1) client pid 1, timebase rate: 1.00, layer time: 79.750 s, host: 1000.000 s, diff: 920.250 s;
FIQCA(0x2) client pid 1, timebase rate: 0.00, layer time: 0.000 s, host: 1000.100 s, diff: 1000.100 s;
"""
let parsed = LockScreenTimeline.parse(sample, duration: 40, now: 1000.2)!
precondition(abs(parsed.position(at: 1000.5) - 0.25) < 0.0001)
precondition(LockScreenTimeline.parse(sample, duration: 40, now: 1100) == nil)
precondition(LockScreenTimeline.parse("unavailable", duration: 40, now: 1000) == nil)
let twoPlayers = """
timebase rate: 1.00, layer time: 30.000 s, host: 1000.000 s
timebase rate: 1.00, layer time: 131.000 s, host: 1000.020 s
"""
let lockPlayer = LockScreenTimeline.parse(twoPlayers, duration: 40, now: 1000.1)!
precondition(lockPlayer.mediaSeconds == 30, "Selected the older desktop renderer instead of the lock-screen renderer")
let paused = PlaybackTimeline(mediaSeconds: 592.125, hostSeconds: 1000, rate: 0, duration: 40)
precondition(abs(paused.position(at: 1500) - 32.125) < 0.0001)
precondition(PlaybackTimeline(mediaSeconds: 0, hostSeconds: 0, rate: 1, duration: 0).position(at: 10) == 0)

Task { @MainActor in
    do {
        let settings = try WallpaperSettings.load()
        let media = URL(fileURLWithPath: settings.mediaPath)
        let asset = AVURLAsset(url: media)
        let duration = try await asset.loadTracks(withMediaType: .video).first!.load(.timeRange).duration.seconds
        let native = await Task.detached { await LockScreenTimeline.resolve(media: media) }.value
        if let native {
            print("Read native clock: media \(native.mediaSeconds), host \(native.hostSeconds), rate \(native.rate)")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        let video = LoopingVideoView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        window.contentView = video
        window.orderBack(nil)
        var checks: [[String: Double]] = []
        for rate in [0.0, 1.0] {
            let clock = PlaybackTimeline(mediaSeconds: min(12.25, duration / 2),
                                         hostSeconds: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                                         rate: rate, duration: duration)
            var presentation: (Double, Double)?
            video.onPresentationReady = {
                presentation = (video.player!.currentTime().seconds,
                                clock.position(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds))
            }
            video.setPlaying(false)
            video.load(url: media, timeline: clock)
            precondition(!video.presented, "Revealed a frame before seeking")
            video.setPlaying(true)
            let deadline = Date().addingTimeInterval(6)
            while presentation == nil {
                precondition(Date() < deadline, "Requested frame was never presented")
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let (actual, expected) = presentation!
            print("Native rate \(rate): presented \(actual), expected \(expected)")
            precondition(abs(actual - expected) < 0.09, "Desktop did not align with the native clock")
            checks.append(["rate": rate, "presented_seconds": actual, "expected_seconds": expected])
            video.unload()
            precondition(!video.presented && video.player == nil)
        }
        video.onPresentationReady = nil
        window.close()
        var testSettings = settings
        testSettings.pauseWhenCovered = false
        let desktop = DesktopController(settings: testSettings)
        var refreshes = 0
        desktop.onHandoffReady = {
            let displays = desktop.diagnostics()["displays"] as! [[String: Any]]
            precondition(displays.allSatisfy { $0["presented"] as? Bool == true },
                         "Refreshed the system renderer before desktop presentation")
            refreshes += 1
        }
        for cycle in 1...2 {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            let locked = desktop.diagnostics()
            precondition(locked["state"] as? String == "Session locked")
            precondition((locked["displays"] as! [[String: Any]]).allSatisfy { $0["queue_items"] as? Int == 0 })
            try await Task.sleep(nanoseconds: 9_500_000_000)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            let deadline = Date().addingTimeInterval(5)
            while refreshes < cycle {
                precondition(Date() < deadline, "Handoff did not finish")
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let state = desktop.diagnostics()
            precondition((state["handoff"] as! [String: Any])["result"] as? String == "native_clock")
            for display in state["displays"] as! [[String: Any]] {
                precondition((display["timeline_error_seconds"] as? Double ?? 100) < 0.09)
            }
        }
        desktop.onHandoffReady = nil
        desktop.stop()
        let result: [String: Any] = ["native_clock_available": native != nil, "checks": checks,
                                   "seek_before_presentation": true, "controller_handoff_cycles": refreshes,
                                   "limitation": "Actual native-clock reads and desktop controller; session events were simulated within this test process, not a real lock/unlock visual check"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "Benchmarks/timeline-handoff.json"), options: .atomic)
        print("Verified native timing parser, stale-clock rejection, and synchronized presentation")
        app.terminate(nil)
    } catch {
        fputs("Timeline test failed: \(error)\n", stderr)
        exit(1)
    }
}
app.run()
