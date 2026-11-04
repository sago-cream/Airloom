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
        rebuildSurfaces()
    }

    var state: String { policy.pauseReason ?? "Playing" }
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
            if shouldUnload {
                surface.video.unload()
            } else {
                if surface.video.player == nil {
                    surface.video.setPlaying(false)
                    surface.video.load(url: URL(fileURLWithPath: settings.mediaPath))
                }
                surface.video.setPlaying(policy.shouldPlay)
            }
        }
        onStateChange?()
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
                ]
            },
        ]
    }

    deinit {
        displayUpdate?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
        for token in distributedObservers { DistributedNotificationCenter.default().removeObserver(token) }
    }
}
