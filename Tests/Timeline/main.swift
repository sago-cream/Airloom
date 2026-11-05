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
        let poster = URL(fileURLWithPath: settings.posterPath ?? WallpaperSettings.posterURL.path)
        video.setPlaceholder(LoopingVideoView.placeholder(from: poster))
        precondition(video.hasPlaceholder, "No still image covers decoder startup")
        window.contentView = video
        window.orderBack(nil)
        var checks: [[String: Double]] = []
        var identity: ObjectIdentifier?
        for rate in [0.0, 1.0] {
            let clock = PlaybackTimeline(mediaSeconds: min(12.25, duration / 2),
                                         hostSeconds: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                                         rate: rate, duration: duration)
            var presentation: (Double, Double)?
            video.onPresentationReady = {
                presentation = (video.player!.currentTime().seconds,
                                clock.position(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds))
            }
            if identity == nil {
                video.setPlaying(false)
                video.load(url: media, timeline: clock)
                identity = ObjectIdentifier(video.player!)
                precondition(!video.presented && video.hasPlaceholder)
            } else { video.synchronize(to: clock) }
            video.setPlaying(true)
            let deadline = Date().addingTimeInterval(6)
            while presentation == nil {
                precondition(Date() < deadline, "Requested frame was never presented")
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let (actual, expected) = presentation!
            precondition(abs(actual - expected) < 0.09, "Desktop did not align with the native clock")
            precondition(ObjectIdentifier(video.player!) == identity && video.loadGeneration == 1,
                         "Synchronization replaced the warm player")
            precondition(!video.hasPlaceholder && video.presented && video.prepared,
                         "Warm playback still depends on a poster")
            checks.append(["rate": rate, "presented_seconds": actual, "expected_seconds": expected])
            video.setPlaying(false)
            let pausedAt = video.player!.currentTime().seconds
            try await Task.sleep(nanoseconds: 200_000_000)
            precondition(abs(video.player!.currentTime().seconds - pausedAt) < 0.02)
            precondition(video.presented && video.prepared, "Pausing discarded the decoded frame")
        }
        video.onPresentationReady = nil
        video.unload()
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
        let initialReady = Date().addingTimeInterval(5)
        while !(desktop.diagnostics()["displays"] as! [[String: Any]]).allSatisfy({ $0["prepared"] as? Bool == true }) {
            precondition(Date() < initialReady)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let initialLoads = (desktop.diagnostics()["displays"] as! [[String: Any]]).map { $0["load_generation"] as! Int }
        var changed = testSettings
        changed.pauseWhenCovered = true
        desktop.update(settings: changed)
        desktop.update(settings: testSettings)
        precondition((desktop.diagnostics()["displays"] as! [[String: Any]]).map { $0["load_generation"] as! Int } == initialLoads,
                     "Changing a playback preference rebuilt the decoder")
        for cycle in SessionState.isLocked ? [] : [1, 2] {
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            try await Task.sleep(nanoseconds: 8_500_000_000)
            if SessionState.isLocked { break }
            let locked = desktop.diagnostics()
            precondition(locked["state"] as? String == "Session locked")
            let lockedDisplays = locked["displays"] as! [[String: Any]]
            precondition(lockedDisplays.allSatisfy { ($0["rate"] as? Float) == 1 && $0["presented"] as? Bool == true },
                         "Desktop was not already playing behind the lock screen")
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            let sleeping = desktop.diagnostics()["displays"] as! [[String: Any]]
            precondition(sleeping.allSatisfy { ($0["rate"] as? Float) == 0 && $0["presented"] as? Bool == true },
                         "Sleep must retain a sharp paused frame without playback")
            if cycle == 1 {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            }
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            let returned = desktop.diagnostics()
            let displays = returned["displays"] as! [[String: Any]]
            precondition(displays.map { $0["load_generation"] as! Int } == initialLoads,
                         "Unlock cold-loaded a replacement decoder")
            precondition(displays.allSatisfy { ($0["rate"] as? Float) == 1 && $0["prepared"] as? Bool == true && $0["placeholder"] as? Bool == false },
                         "Unlock did not immediately continue the prepared player")
            precondition((returned["handoff"] as! [String: Any])["ready_before_unlock"] as? Bool == true)
            precondition((returned["handoff"] as! [String: Any])["after_sleep"] as? Bool == true)
            if cycle == 2 {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
                let lateWake = desktop.diagnostics()["displays"] as! [[String: Any]]
                precondition(lateWake.allSatisfy { ($0["rate"] as? Float) == 1 && $0["prepared"] as? Bool == true },
                             "A late display-wake event interrupted resumed playback")
            }
            precondition(refreshes == cycle, "Native renderer refresh did not wait for warm desktop playback")
        }
        desktop.onHandoffReady = nil
        desktop.stop()
        let result: [String: Any] = ["native_clock_available": native != nil, "checks": checks,
                                   "seek_before_presentation": true, "controller_handoff_cycles": refreshes,
                                   "one_player_across_lock_sleep_unlock": true, "ready_before_unlock": true,
                                   "limitation": "Native-clock lookup and actual desktop controller; session events were simulated within this test process, not a real lock/unlock visual check"]
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
