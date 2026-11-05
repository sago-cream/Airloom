import AppKit
import ServiceManagement
import Sparkle
import UniformTypeIdentifiers
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: DesktopController?
    private var statusItem: NSStatusItem?
    private var updater: SPUStandardUpdaterController?
    private var updateItem: NSMenuItem?
    private var stateItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var commandObserver: NSObjectProtocol?
    private var settings: WallpaperSettings?
    private var importing = false
    private var importItem: NSMenuItem?
    private var coverageItem: NSMenuItem?
    private var lockScreenItem: NSMenuItem?
    private var lockScreenBusy = false
    private var lockScreenError = ""
    private var sessionLocked = false
    private var lockObservers: [NSObjectProtocol] = []
    private var loginItem: NSMenuItem?
    private var rendererRefresh: DispatchWorkItem?
    private var menuTracking = false
    private var outsideClickMonitor: Any?
    private var deactivationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        var loaded = (try? WallpaperSettings.load()) ?? WallpaperSettings(sourcePath: "", mediaPath: "", title: "Airloom")
        let hasWallpaper = FileManager.default.isReadableFile(atPath: loaded.mediaPath)
        if hasWallpaper {
            do { try DesktopImageManager.applyPoster(settings: &loaded) }
            catch { NSLog("Airloom: could not set the matching still: %@", error.localizedDescription) }
        }
        settings = loaded
        sessionLocked = SessionState.isLocked
        observeLockLifecycle()
        if hasWallpaper { startDesktop(settings: loaded) }
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "wind", accessibilityDescription: "Airloom wallpaper")
        item.button?.toolTip = "Airloom — \(loaded.title)"
        item.menu = makeMenu()
        statusItem = item
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.dismissMenu() }
        commandObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.hsi.Torii.command"), object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            switch notification.userInfo?["command"] as? String {
            case "pause": self.controller?.setPaused(true)
            case "resume": self.controller?.setPaused(false)
            case "show": self.showMenu()
            case "snapshot": self.writeDiagnostics()
            case "quit": NSApp.terminate(nil)
            case "continuous": self.setCoveragePause(false)
            case "efficient": self.setCoveragePause(true)
            case "lock-screen-on": self.setLockScreen(true)
            case "lock-screen-off": self.setLockScreen(false)
            default: break
            }
        }
        writeDiagnostics()
        if hasWallpaper, loaded.lockScreenSlotID != nil, LockScreenInstaller.state()?.mediaPath != loaded.mediaPath {
            setLockScreen(true)
        }
        if !hasWallpaper, !sessionLocked {
            DispatchQueue.main.async { self.importVideo() }
        } else if CommandLine.arguments.contains("--show") { showMenu() }
    }

    private func startDesktop(settings loaded: WallpaperSettings) {
        controller = DesktopController(settings: loaded)
        controller?.onStateChange = { [weak self] in self?.updateState() }
        controller?.onHandoffReady = { [weak self] in
            guard let self else { return }
            self.rendererRefresh?.cancel()
            let refresh = DispatchWorkItem { [weak self] in
                guard let self, !self.sessionLocked, self.settings?.lockScreenSlotID != nil else { return }
                LockScreenInstaller.reload(includeAgent: false)
            }
            self.rendererRefresh = refresh
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: refresh)
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector? = nil, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
            return item
        }
        stateItem = item("Airloom")
        stateItem?.isEnabled = false
        menu.addItem(.separator())
        pauseItem = item("Pause Wallpaper", #selector(togglePause), key: "p")
        importItem = item("Import Video…", #selector(importVideo), key: "o")
        menu.addItem(.separator())
        coverageItem = item("Pause When Desktop Is Covered", #selector(toggleCoveragePause))
        lockScreenItem = item("Animate Lock Screen", #selector(toggleLockScreen))
        loginItem = item("Start at Login", #selector(toggleLogin))
        menu.addItem(.separator())
        updateItem = item("Check for Updates…", #selector(checkForUpdates))
        _ = item("Quit Airloom", #selector(quit), key: "q")
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuTracking = true
        updateState()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in self?.dismissMenu()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTracking = false
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        releaseTemporaryMemory()
    }

    private func dismissMenu() {
        guard menuTracking else { return }
        statusItem?.menu?.cancelTracking()
    }

    private func showMenu() {
        guard !menuTracking else { return }
        updateState()
        guard let button = statusItem?.button, let menu = statusItem?.menu else { return }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
    }

    @objc private func togglePause() {
        controller?.setPaused(!(controller?.userPaused ?? false))
    }

    @objc private func toggleCoveragePause() {
        setCoveragePause(settings?.pauseWhenCovered == false)
    }

    private func setCoveragePause(_ enabled: Bool) {
        guard var settings else { return }
        settings.pauseWhenCovered = enabled
        do {
            try settings.save()
            self.settings = settings
            controller?.update(settings: settings)
            coverageItem?.state = enabled ? .on : .off
        } catch { showError(error.localizedDescription) }
    }

    @objc private func toggleLockScreen() {
        setLockScreen(settings?.lockScreenSlotID == nil)
    }

    private func setLockScreen(_ enabled: Bool) {
        guard !lockScreenBusy, !importing, var updated = settings else { return }
        lockScreenBusy = true
        lockScreenError = ""
        lockScreenItem?.isEnabled = false
        updateState()
        writeDiagnostics()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if enabled {
                    updated.lockScreenSlotID = try await LockScreenInstaller.install(settings: updated)
                } else {
                    try LockScreenInstaller.restore()
                    updated.lockScreenSlotID = nil
                }
                try updated.save()
                self.settings = updated
                self.controller?.update(settings: updated)
                if !self.sessionLocked { LockScreenInstaller.reload(includeAgent: true) }
            } catch {
                self.lockScreenError = error.localizedDescription
                self.showError(error.localizedDescription)
            }
            self.lockScreenBusy = false
            self.lockScreenItem?.isEnabled = true
            self.lockScreenItem?.state = self.settings?.lockScreenSlotID != nil ? .on : .off
            self.updateState()
            self.releaseTemporaryMemory()
        }
    }

    private func observeLockLifecycle() {
        let center = DistributedNotificationCenter.default()
        lockObservers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.sessionLocked = true
            self?.rendererRefresh?.cancel()
            self?.dismissMenu()
        })
        lockObservers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sessionLocked = false
        })
    }

    @objc private func importVideo() {
        guard !importing, !lockScreenBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Wallpaper Video"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = settings.flatMap { $0.sourcePath.isEmpty ? nil : URL(fileURLWithPath: $0.sourcePath).deletingLastPathComponent() }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/wallpaper")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSource(url)
    }

    private func importSource(_ source: URL) {
        guard !importing, let previous = settings else { return }
        importing = true
        importItem?.isEnabled = false
        updateState()
        Task { @MainActor [weak self] in
            guard let self else { return }
            var preparedImport: PreparedVideo?
            do {
                let prepared = try await VideoImporter.prepare(source: source)
                preparedImport = prepared
                var updated = try VideoImporter.activate(prepared, previous: previous)
                preparedImport = nil
                if previous.lockScreenSlotID != nil {
                    do { updated.lockScreenSlotID = try await LockScreenInstaller.install(settings: updated) }
                    catch { self.showError("The desktop video was imported, but the lock screen could not be updated: \(error.localizedDescription)") }
                }
                do { try DesktopImageManager.applyPoster(settings: &updated) }
                catch { NSLog("Airloom: could not update the matching still: %@", error.localizedDescription) }
                self.settings = updated
                if updated.lockScreenSlotID != nil, !self.sessionLocked { LockScreenInstaller.reload(includeAgent: true) }
                if let controller = self.controller { controller.update(settings: updated) }
                else { self.startDesktop(settings: updated) }
                VideoImporter.removePreviousMedia(previous, keeping: updated)
            } catch {
                if let preparedImport { try? FileManager.default.removeItem(at: preparedImport.directory) }
                self.showError(error.localizedDescription)
            }
            self.importing = false
            self.importItem?.isEnabled = true
            self.updateState()
            self.releaseTemporaryMemory()
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch { showError(error.localizedDescription) }
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func checkForUpdates(_ sender: Any?) { updater?.checkForUpdates(sender) }

    @objc private func quit() { NSApp.terminate(nil) }

    private func releaseTemporaryMemory() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { malloc_zone_pressure_relief(nil, 0) }
    }

    private func updateState() {
        let state = importing ? "Importing…" : lockScreenBusy ? "Preparing Lock Screen…" : controller?.state ?? "Choose a Video…"
        stateItem?.title = "Airloom — \(state)"
        updateItem?.isEnabled = updater?.updater.canCheckForUpdates == true
        importItem?.isEnabled = !importing && !lockScreenBusy
        pauseItem?.isEnabled = controller != nil
        coverageItem?.isEnabled = controller != nil
        lockScreenItem?.isEnabled = controller != nil && !importing && !lockScreenBusy
        pauseItem?.title = controller?.userPaused == true ? "Resume Wallpaper" : "Pause Wallpaper"
        coverageItem?.state = settings?.pauseWhenCovered == false ? .off : .on
        lockScreenItem?.state = settings?.lockScreenSlotID != nil ? .on : .off
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        statusItem?.button?.appearsDisabled = controller?.userPaused == true
        statusItem?.button?.toolTip = settings.map { "Airloom — \($0.title)" }
        writeDiagnostics()
    }

    private func writeDiagnostics() {
        guard var diagnostics = controller?.diagnostics() else { return }
        diagnostics["lock_screen"] = ["enabled": settings?.lockScreenSlotID != nil,
                                      "busy": lockScreenBusy, "slot_id": settings?.lockScreenSlotID ?? "",
                                      "error": lockScreenError]
        diagnostics["menu"] = ["tracking": menuTracking, "outside_click_monitor": outsideClickMonitor != nil]
        guard let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: WallpaperSettings.supportURL.appendingPathComponent("status.json"), options: .atomic)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Airloom"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dismissMenu()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        controller?.stop()
        rendererRefresh?.cancel()
        for token in lockObservers { DistributedNotificationCenter.default().removeObserver(token) }
        if let commandObserver { DistributedNotificationCenter.default().removeObserver(commandObserver) }
    }
}
