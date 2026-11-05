import AppKit
import Darwin
import AVFoundation

private final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DesktopController {
    private final class Surface {
        let window: NSWindow
        let video: LoopingVideoView
        let screenID: String
        var resumeSeconds: Double = 0

        init(window: NSWindow, video: LoopingVideoView, screenID: String) {
            self.window = window
            self.video = video
            self.screenID = screenID
        }
    }

    private var surfaces: [Surface] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var displayUpdate: DispatchWorkItem?
    private var visibilityTimer: Timer?
    private var coveredScreens = Set<String>()
    private var policy = PlaybackPolicy()
    private var settings: WallpaperSettings
    private var lockPlaybackActive = false
    private var handoffGeneration = 0
    private var handoffDiagnostics: [String: Any] = [:]
    private var nativeRefreshNeeded = false
    private var nativeClock: PlaybackTimeline?
    private var clockSample: Task<Void, Never>?
    private var unlockGraceUntil = Date.distantPast
    private var graceEnd: DispatchWorkItem?
    private var sleptSinceUnlock = false
    var onHandoffReady: (() -> Void)?
    var onStateChange: (() -> Void)?

    init(settings: WallpaperSettings) {
        self.settings = settings
        policy.sessionInactive = SessionState.isLocked
        lockPlaybackActive = policy.sessionInactive && settings.lockScreenSlotID != nil
        nativeRefreshNeeded = lockPlaybackActive
        policy.lowPowerMode = settings.pauseInLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled
        observe(NSWorkspace.willSleepNotification) { $0.prepareForSleep() }
        observe(NSWorkspace.screensDidSleepNotification) { $0.prepareForSleep() }
        observe(NSWorkspace.didWakeNotification) {
            $0.policy.screenSleeping = false
            if $0.policy.sessionInactive { $0.sampleNativeClock(after: 0.2) }
        }
        observe(NSWorkspace.screensDidWakeNotification) {
            $0.policy.screenSleeping = false
            if $0.policy.sessionInactive { $0.sampleNativeClock(after: 0.2) }
        }
        observe(NSWorkspace.sessionDidResignActiveNotification) { $0.sessionResigned() }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) {
            if !SessionState.isLocked { $0.sessionReturned() }
        }
        observeDistributed("com.apple.screenIsLocked") { $0.sessionResigned() }
        observeDistributed("com.apple.screenIsUnlocked") { $0.sessionReturned() }
        observeDistributed("com.apple.screensaver.didstart") {
            $0.policy.screenSaverActive = true
            $0.beginLockPlayback()
        }
        observeDistributed("com.apple.screensaver.didstop") {
            $0.policy.screenSaverActive = false
            if !$0.policy.sessionInactive { $0.finishLockPlayback() }
        }
        let power = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.policy.lowPowerMode = self.settings.pauseInLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled
            self.applyPolicy()
        }
        observers.append((.default, power))
        let displays = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.displayUpdate?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.rebuildSurfaces() }
            self.displayUpdate = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        observers.append((.default, displays))
        let occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow,
                  self.surfaces.contains(where: { $0.window === window }) else { return }
            self.applyPolicy()
        }
        observers.append((.default, occlusion))
        observe(NSWorkspace.didActivateApplicationNotification) { $0.refreshCoverage() }
        observe(NSWorkspace.activeSpaceDidChangeNotification) { $0.refreshCoverage() }
        // Window geometry has no public cross-process change notification. Poll slowly, with
        // timer coalescing, to catch resizes without Accessibility or Screen Recording access.
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshCoverage()
        }
        visibilityTimer?.tolerance = 1
        rebuildSurfaces()
        refreshCoverage()
        if lockPlaybackActive { sampleNativeClock(after: 0.2) }
    }

    var state: String {
        if let reason = policy.pauseReason { return reason }
        if surfaces.contains(where: { $0.video.failure != nil }) { return "Playback failed" }
        return surfaces.contains { isVisible($0) } ? "Playing" : "Desktop covered"
    }
    var userPaused: Bool { policy.userPaused }

    func setPaused(_ paused: Bool) {
        policy.userPaused = paused
        if !paused, lockPlaybackActive { sampleNativeClock(after: 0.2) }
        applyPolicy()
    }

    func update(settings: WallpaperSettings) {
        let sourceChanged = self.settings.mediaPath != settings.mediaPath
        let lockModeChanged = self.settings.lockScreenSlotID != settings.lockScreenSlotID
        self.settings = settings
        policy.lowPowerMode = settings.pauseInLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled
        if sourceChanged || lockModeChanged {
            clockSample?.cancel()
            nativeClock = nil
            handoffGeneration += 1
            lockPlaybackActive = (policy.sessionInactive || policy.screenSaverActive) && settings.lockScreenSlotID != nil
            nativeRefreshNeeded = lockPlaybackActive
            if sourceChanged { rebuildSurfaces() }
            if lockPlaybackActive { sampleNativeClock(after: 0.2) }
        }
        applyPolicy()
    }

    private func beginLockPlayback() {
        guard settings.lockScreenSlotID != nil, !lockPlaybackActive else { return }
        lockPlaybackActive = true
        nativeRefreshNeeded = true
        handoffGeneration += 1
        nativeClock = nil
        handoffDiagnostics = ["result": "preparing_behind_lock"]
        sampleNativeClock(after: 0.2)
    }

    private func sampleNativeClock(after delay: Double) {
        guard settings.lockScreenSlotID != nil else { return }
        clockSample?.cancel()
        let generation = handoffGeneration
        let media = URL(fileURLWithPath: settings.mediaPath)
        clockSample = Task { @MainActor [weak self] in
            // The first read catches short locks; the second includes the renderer's periodic stats.
            for wait in [delay, 6.5] {
                do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                catch { return }
                let clock = await Task.detached(priority: .utility) { await LockScreenTimeline.resolve(media: media) }.value
                guard let self, !Task.isCancelled, self.handoffGeneration == generation,
                      self.lockPlaybackActive else { return }
                guard let clock, !self.policy.screenSleeping, !self.policy.userPaused,
                      !self.policy.lowPowerMode else { continue }
                self.nativeClock = clock
                for surface in self.surfaces { surface.video.synchronize(to: clock) }
                self.handoffDiagnostics = ["result": "aligned_behind_lock", "media_anchor": clock.mediaSeconds,
                                           "host_anchor": clock.hostSeconds, "native_rate": clock.rate]
                self.applyPolicy()
            }
        }
    }

    private func sessionResigned() {
        policy.sessionInactive = true
        beginLockPlayback()
    }

    private func prepareForSleep() {
        policy.screenSleeping = true
        sleptSinceUnlock = true
        handoffGeneration += 1
        clockSample?.cancel()
        nativeClock = nil
    }

    private func sessionReturned() {
        // Authentication establishes an awake interactive session even if the display-wake
        // notification is still queued. Keep manual pause and Low Power Mode independent.
        policy.screenSleeping = false
        policy.sessionInactive = false
        finishLockPlayback()
    }

    private func finishLockPlayback() {
        guard lockPlaybackActive else { return }
        lockPlaybackActive = false
        handoffGeneration += 1
        clockSample?.cancel()
        // Keep the already-presented player through the login-window fade and coverage refresh.
        unlockGraceUntil = Date().addingTimeInterval(1)
        handoffDiagnostics["result"] = "warm_resume"
        handoffDiagnostics["ready_before_unlock"] = surfaces.allSatisfy { $0.video.prepared && $0.video.presented }
        handoffDiagnostics["after_sleep"] = sleptSinceUnlock
        sleptSinceUnlock = false
        graceEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            self?.refreshCoverage()
            self?.applyPolicy()
        }
        graceEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: end)
        refreshCoverage()
    }

    func stop() {
        displayUpdate?.cancel()
        for surface in surfaces {
            surface.video.unload()
            surface.window.orderOut(nil)
            surface.window.close()
        }
        surfaces.removeAll()
    }

    private func rebuildSurfaces() {
        stop()
        let posterURL = settings.posterPath.map { URL(fileURLWithPath: $0) } ?? WallpaperSettings.posterURL
        let poster = autoreleasepool { LoopingVideoView.placeholder(from: posterURL) }
        for screen in NSScreen.screens {
            let window = WallpaperWindow(
                contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isExcludedFromWindowsMenu = true
            window.title = "Torii Wallpaper"
            let view = LoopingVideoView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.setPlaceholder(poster)
            view.onFailure = { [weak self] in self?.onStateChange?() }
            view.onPresentationReady = { [weak self] in self?.applyPolicy() }
            window.contentView = view
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "unknown"
            surfaces.append(Surface(window: window, video: view, screenID: displayID))
            window.orderBack(nil)
        }
        applyPolicy()
    }

    private func applyPolicy() {
        for surface in surfaces {
            if surface.video.player == nil {
                surface.video.setPlaying(false)
                surface.video.load(url: URL(fileURLWithPath: settings.mediaPath), resumeAt: surface.resumeSeconds)
            }
            surface.video.setPlaying(policy.shouldAnimate(visible: isVisible(surface),
                nativeLockScreen: settings.lockScreenSlotID != nil, unlockGrace: Date() < unlockGraceUntil))
        }
        if nativeRefreshNeeded, !lockPlaybackActive, !policy.sessionInactive, !policy.screenSaverActive, !policy.screenSleeping,
           surfaces.allSatisfy({ $0.video.prepared && $0.video.presented }) {
            nativeRefreshNeeded = false
            onHandoffReady?()
        }
        onStateChange?()
    }

    private func isVisible(_ surface: Surface) -> Bool {
        if settings.pauseWhenCovered == false { return true }
        return surface.window.occlusionState.contains(.visible) && !coveredScreens.contains(surface.screenID)
    }

    private func refreshCoverage() {
        guard !policy.sessionInactive, !policy.screenSleeping, !policy.screenSaverActive,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }
        let rectangles = windows.compactMap { info -> CGRect? in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != ProcessInfo.processInfo.processIdentifier,
                  (info[kCGWindowAlpha as String] as? Double ?? 0) >= 0.99,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rectangle = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return rectangle
        }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let updated = Set(NSScreen.screens.compactMap { screen -> String? in
            let frame = screen.visibleFrame
            let cgFrame = CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
            guard WindowCoverage.isCovered(cgFrame, by: rectangles) else { return nil }
            return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
        })
        guard coveredScreens != updated else { return }
        coveredScreens = updated
        applyPolicy()
    }

    private func observe(_ name: Notification.Name, change: @escaping (DesktopController) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            change(self)
            self.applyPolicy()
        }
        observers.append((center, token))
    }

    private func observeDistributed(_ name: String, change: @escaping (DesktopController) -> Void) {
        let token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(name), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            change(self)
            self.applyPolicy()
        }
        distributedObservers.append(token)
    }

    func diagnostics() -> [String: Any] {
        [
            "state": state,
            "source": settings.sourcePath,
            "media": settings.mediaPath,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "handoff": handoffDiagnostics,
            "power": ["sleeping": policy.screenSleeping, "slept_since_unlock": sleptSinceUnlock],
            "native_clock_sample": nativeClock.map { ["media_seconds": $0.mediaSeconds, "host_seconds": $0.hostSeconds, "rate": $0.rate] } ?? [:],
            "displays": surfaces.map { surface -> [String: Any] in
                let player = surface.video.player
                let time = player?.currentTime().seconds ?? surface.resumeSeconds
                var info: [String: Any] = [
                    "id": surface.screenID,
                    "rate": player?.rate ?? 0,
                    "time_seconds": time.isFinite ? time : 0,
                    "queue_items": player?.items().count ?? 0,
                    "ready": player?.currentItem?.status == .readyToPlay,
                    "presented": surface.video.presented,
                    "placeholder": surface.video.hasPlaceholder,
                    "load_generation": surface.video.loadGeneration,
                    "prepared": surface.video.prepared,
                    "error": surface.video.failure ?? "",
                    "window_level": surface.window.level.rawValue,
                    "visible": isVisible(surface),
                    "window_frame": NSStringFromRect(surface.window.frame),
                ]
                if let error = surface.video.timelineError { info["timeline_error_seconds"] = error }
                return info
            },
        ]
    }

    deinit {
        displayUpdate?.cancel()
        clockSample?.cancel()
        visibilityTimer?.invalidate()
        graceEnd?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
        for token in distributedObservers { DistributedNotificationCenter.default().removeObserver(token) }
    }
}
