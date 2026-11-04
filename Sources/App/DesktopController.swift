import AppKit

private final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DesktopController {
    private struct Surface {
        let window: NSWindow
        let video: LoopingVideoView
        let screenID: String
    }

    private var surfaces: [Surface] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var displayUpdate: DispatchWorkItem?
    private var visibilityTimer: Timer?
    private var coveredScreens = Set<String>()
    private var policy = PlaybackPolicy()
    private var settings: WallpaperSettings
    var onStateChange: (() -> Void)?

    init(settings: WallpaperSettings) {
        self.settings = settings
        policy.lowPowerMode = settings.pauseInLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled
        observe(NSWorkspace.willSleepNotification) { $0.policy.screenSleeping = true }
        observe(NSWorkspace.screensDidSleepNotification) { $0.policy.screenSleeping = true }
        observe(NSWorkspace.didWakeNotification) { $0.policy.screenSleeping = false }
        observe(NSWorkspace.screensDidWakeNotification) { $0.policy.screenSleeping = false }
        observe(NSWorkspace.sessionDidResignActiveNotification) { $0.policy.sessionInactive = true }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { $0.policy.sessionInactive = false }
        observeDistributed("com.apple.screenIsLocked") { $0.policy.sessionInactive = true }
        observeDistributed("com.apple.screenIsUnlocked") { $0.policy.sessionInactive = false }
        observeDistributed("com.apple.screensaver.didstart") { $0.policy.screenSaverActive = true }
        observeDistributed("com.apple.screensaver.didstop") { $0.policy.screenSaverActive = false }
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
    }

    var state: String {
        if let reason = policy.pauseReason { return reason }
        if surfaces.contains(where: { $0.video.failure != nil }) { return "Playback failed" }
        return surfaces.contains { isVisible($0) } ? "Playing" : "Desktop covered"
    }
    var userPaused: Bool { policy.userPaused }

    func setPaused(_ paused: Bool) {
        policy.userPaused = paused
        applyPolicy()
    }

    func update(settings: WallpaperSettings) {
        self.settings = settings
        rebuildSurfaces()
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
        for screen in NSScreen.screens {
            let window = WallpaperWindow(
                contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.isExcludedFromWindowsMenu = true
            window.title = "Torii Wallpaper"
            let view = LoopingVideoView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onFailure = { [weak self] in self?.onStateChange?() }
            window.contentView = view
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "unknown"
            surfaces.append(Surface(window: window, video: view, screenID: displayID))
            window.orderBack(nil)
        }
        applyPolicy()
    }

    private func applyPolicy() {
        let shouldUnload = policy.sessionInactive || policy.screenSleeping || policy.screenSaverActive
        for surface in surfaces {
            let visible = isVisible(surface)
            if shouldUnload {
                surface.video.unload()
            } else {
                if surface.video.player == nil && visible {
                    surface.video.setPlaying(false)
                    surface.video.load(url: URL(fileURLWithPath: settings.mediaPath))
                }
                surface.video.setPlaying(policy.shouldPlay && visible)
            }
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
            "displays": surfaces.map { surface -> [String: Any] in
                let player = surface.video.player
                let time = player?.currentTime().seconds ?? 0
                return [
                    "id": surface.screenID,
                    "rate": player?.rate ?? 0,
                    "time_seconds": time.isFinite ? time : 0,
                    "queue_items": player?.items().count ?? 0,
                    "ready": player?.currentItem?.status == .readyToPlay,
                    "error": surface.video.failure ?? "",
                    "window_level": surface.window.level.rawValue,
                    "visible": isVisible(surface),
                    "window_frame": NSStringFromRect(surface.window.frame),
                ]
            },
        ]
    }

    deinit {
        displayUpdate?.cancel()
        visibilityTimer?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
        for token in distributedObservers { DistributedNotificationCenter.default().removeObserver(token) }
    }
}
