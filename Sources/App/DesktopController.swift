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
    private var memoryRelease: DispatchWorkItem?
    private var policy = PlaybackPolicy()
    private var settings: WallpaperSettings
    private var handoffNeeded = false
    private var handoffPending = false
    private var handoffTask: Task<Void, Never>?
    private var handoffGeneration = 0
    private var handoffDiagnostics: [String: Any] = [:]
    private var handoffFade = 0.0
    private var resumeTimeline: PlaybackTimeline?
    private var nativeRefreshNeeded = false
    private var nativeClock: PlaybackTimeline?
    private var clockSample: Task<Void, Never>?
    var onHandoffReady: (() -> Void)?
    var onStateChange: (() -> Void)?

    init(settings: WallpaperSettings) {
        self.settings = settings
        policy.sessionInactive = SessionState.isLocked
        handoffNeeded = policy.sessionInactive && settings.lockScreenSlotID != nil
        nativeRefreshNeeded = handoffNeeded
        policy.lowPowerMode = settings.pauseInLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled
        observe(NSWorkspace.willSleepNotification) { $0.policy.screenSleeping = true }
        observe(NSWorkspace.screensDidSleepNotification) { $0.policy.screenSleeping = true }
        observe(NSWorkspace.didWakeNotification) {
            $0.policy.screenSleeping = false
            if $0.policy.sessionInactive { $0.sampleNativeClock(after: 0) }
        }
        observe(NSWorkspace.screensDidWakeNotification) {
            $0.policy.screenSleeping = false
            if $0.policy.sessionInactive { $0.sampleNativeClock(after: 0) }
        }
        observe(NSWorkspace.sessionDidResignActiveNotification) { $0.sessionResigned() }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) {
            if !SessionState.isLocked { $0.sessionReturned() }
        }
        observeDistributed("com.apple.screenIsLocked") { $0.sessionResigned() }
        observeDistributed("com.apple.screenIsUnlocked") { $0.sessionReturned() }
        observeDistributed("com.apple.screensaver.didstart") {
            $0.policy.screenSaverActive = true
            $0.markHandoffNeeded()
        }
        observeDistributed("com.apple.screensaver.didstop") {
            $0.policy.screenSaverActive = false
            if !$0.policy.sessionInactive { $0.beginHandoff() }
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
        if handoffNeeded { sampleNativeClock(after: 0) }
    }

    var state: String {
        if let reason = policy.pauseReason { return reason }
        if handoffPending { return "Resuming" }
        if surfaces.contains(where: { $0.video.failure != nil }) { return "Playback failed" }
        return surfaces.contains { isVisible($0) } ? "Playing" : "Desktop covered"
    }
    var userPaused: Bool { policy.userPaused }

    func setPaused(_ paused: Bool) {
        policy.userPaused = paused
        applyPolicy()
    }

    func update(settings: WallpaperSettings) {
        handoffTask?.cancel()
        clockSample?.cancel()
        nativeClock = nil
        resumeTimeline = nil
        handoffGeneration += 1
        handoffPending = false
        handoffNeeded = policy.sessionInactive && settings.lockScreenSlotID != nil
        nativeRefreshNeeded = handoffNeeded
        self.settings = settings
        rebuildSurfaces()
        if handoffNeeded { sampleNativeClock(after: 0) }
    }

    private func markHandoffNeeded() {
        guard settings.lockScreenSlotID != nil else { return }
        nativeRefreshNeeded = true
        resumeTimeline = nil
        handoffNeeded = true
        handoffPending = true
        handoffTask?.cancel()
        handoffTask = nil
        handoffGeneration += 1
        nativeClock = nil
        sampleNativeClock(after: 6.5)
    }

    private func sampleNativeClock(after delay: Double) {
        guard settings.lockScreenSlotID != nil else { return }
        clockSample?.cancel()
        let generation = handoffGeneration
        let media = URL(fileURLWithPath: settings.mediaPath)
        clockSample = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            let clock = await Task.detached(priority: .utility) { await LockScreenTimeline.resolve(media: media) }.value
            guard let self, !Task.isCancelled, self.handoffGeneration == generation else { return }
            self.nativeClock = clock
        }
    }

    private func sessionResigned() {
        policy.sessionInactive = true
        markHandoffNeeded()
    }

    private func sessionReturned() {
        policy.sessionInactive = false
        beginHandoff()
    }

    private func beginHandoff() {
        guard handoffNeeded, handoffTask == nil else { return }
        handoffPending = true
        let generation = handoffGeneration
        let media = URL(fileURLWithPath: settings.mediaPath)
        let sampled = nativeClock
        clockSample?.cancel()
        handoffTask = Task { @MainActor [weak self] in
            let match: PlaybackTimeline?
            if let sampled { match = sampled }
            else {
                match = await Task.detached(priority: .userInitiated) {
                    await LockScreenTimeline.resolve(media: media)
                }.value
            }
            guard let self, !Task.isCancelled, generation == self.handoffGeneration else { return }
            if let match {
                self.resumeTimeline = match
                let position = match.position(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
                for surface in self.surfaces { surface.resumeSeconds = position }
                self.handoffFade = 0
                self.handoffDiagnostics = ["result": "native_clock", "time_seconds": position,
                                           "media_anchor": match.mediaSeconds, "host_anchor": match.hostSeconds, "native_rate": match.rate]
            } else {
                self.handoffFade = 0.25
                self.handoffDiagnostics = ["result": "fade_fallback", "reason": "Native playback timing was unavailable"]
            }
            self.handoffNeeded = false
            self.handoffPending = false
            self.handoffTask = nil
            self.applyPolicy()
            malloc_zone_pressure_relief(nil, 0)
        }
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
        let shouldUnload = !policy.shouldPlay || handoffPending
        var releasedResources = false
        for surface in surfaces {
            let visible = isVisible(surface)
            if shouldUnload || !visible {
                if let player = surface.video.player {
                    let time = player.currentTime().seconds
                    if time.isFinite { surface.resumeSeconds = time }
                    surface.video.unload(preserveFrame: true)
                    releasedResources = true
                }
            } else {
                if surface.video.player == nil && visible {
                    surface.video.setPlaying(false)
                    surface.video.fadeInDuration = handoffFade
                    surface.video.load(url: URL(fileURLWithPath: settings.mediaPath), resumeAt: surface.resumeSeconds, timeline: resumeTimeline)
                }
                surface.video.setPlaying(policy.shouldPlay && visible)
            }
        }
        if nativeRefreshNeeded, !handoffPending, !policy.sessionInactive,
           surfaces.allSatisfy({ $0.video.presented || !isVisible($0) || policy.userPaused }) {
            nativeRefreshNeeded = false
            resumeTimeline = nil
            onHandoffReady?()
        }
        if releasedResources {
            memoryRelease?.cancel()
            // AVFoundation finishes teardown asynchronously. Return unused allocator pages
            // after that drain, rather than retaining decoder allocations while hidden.
            let release = DispatchWorkItem { malloc_zone_pressure_relief(nil, 0) }
            memoryRelease = release
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: release)
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
        handoffTask?.cancel()
        clockSample?.cancel()
        visibilityTimer?.invalidate()
        memoryRelease?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
        for token in distributedObservers { DistributedNotificationCenter.default().removeObserver(token) }
    }
}
