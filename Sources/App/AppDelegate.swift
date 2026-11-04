import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import ImageIO
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var controller: DesktopController?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var stateLabel: NSTextField?
    private var pauseButton: NSButton?
    private var commandObserver: NSObjectProtocol?
    private var settings: WallpaperSettings?
    private var importing = false
    private var importButton: NSButton?
    private var coverageCheckbox: NSButton?
    private var lockScreenCheckbox: NSButton?
    private var lockScreenBusy = false
    private var lockScreenError = ""
    private var sessionLocked = false
    private var lockObservers: [NSObjectProtocol] = []
    private var rendererRefresh: DispatchWorkItem?
    private var loginCheckbox: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard var loaded = try? WallpaperSettings.load(),
              FileManager.default.isReadableFile(atPath: loaded.mediaPath) else {
            showError("No wallpaper is installed. Run Scripts/install.sh with a video file, then reopen Torii.")
            NSApp.terminate(nil)
            return
        }
        do { try DesktopImageManager.applyPoster(settings: &loaded) }
        catch { NSLog("Torii: could not set the matching lock-screen still: %@", error.localizedDescription) }
        settings = loaded
        sessionLocked = SessionState.isLocked
        observeLockLifecycle()
        controller = DesktopController(settings: loaded)
        controller?.onStateChange = { [weak self] in self?.updateState() }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "mountain.2", accessibilityDescription: "Torii wallpaper")
        item.button?.toolTip = "Torii — \(loaded.title)"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.delegate = self
        statusItem = item
        commandObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.hsi.Torii.command"), object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            switch notification.userInfo?["command"] as? String {
            case "pause": self.controller?.setPaused(true)
            case "resume": self.controller?.setPaused(false)
            case "show": self.showPanel()
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
        if loaded.lockScreenSlotID != nil, LockScreenInstaller.state()?.mediaPath != loaded.mediaPath {
            setLockScreen(true)
        }
        if CommandLine.arguments.contains("--show") { showPanel() }
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) } else { showPanel() }
    }

    @objc private func togglePause() {
        controller?.setPaused(!(controller?.userPaused ?? false))
    }

    @objc private func toggleCoveragePause(_ sender: NSButton) {
        setCoveragePause(sender.state == .on)
    }

    private func setCoveragePause(_ enabled: Bool) {
        guard var settings else { return }
        settings.pauseWhenCovered = enabled
        do {
            try settings.save()
            self.settings = settings
            controller?.update(settings: settings)
            coverageCheckbox?.state = enabled ? .on : .off
        } catch { showError(error.localizedDescription) }
    }

    @objc private func toggleLockScreen(_ sender: NSButton) {
        setLockScreen(sender.state == .on)
    }

    private func setLockScreen(_ enabled: Bool) {
        guard !lockScreenBusy, !importing, var updated = settings else { return }
        lockScreenBusy = true
        lockScreenError = ""
        lockScreenCheckbox?.isEnabled = false
        stateLabel?.stringValue = "Preparing lock screen…"
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
                if !self.sessionLocked { LockScreenInstaller.reload(includeAgent: true) }
            } catch {
                self.lockScreenError = error.localizedDescription
                self.showError(error.localizedDescription)
            }
            self.lockScreenBusy = false
            self.lockScreenCheckbox?.isEnabled = true
            self.lockScreenCheckbox?.state = self.settings?.lockScreenSlotID != nil ? .on : .off
            self.updateState()
            self.releaseTemporaryMemory()
        }
    }

    private func observeLockLifecycle() {
        let center = DistributedNotificationCenter.default()
        lockObservers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.sessionLocked = true
            self?.rendererRefresh?.cancel()
        })
        lockObservers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sessionLocked = false
            self.rendererRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.sessionLocked, self.settings?.lockScreenSlotID != nil else { return }
                LockScreenInstaller.reload(includeAgent: false)
            }
            self.rendererRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
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
        panel.directoryURL = settings.map { URL(fileURLWithPath: $0.sourcePath).deletingLastPathComponent() }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/wallpaper")
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSource(url)
    }

    private func importSource(_ source: URL) {
        guard !importing, let previous = settings else { return }
        importing = true
        importButton?.isEnabled = false
        stateLabel?.stringValue = "Importing…"
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
                catch { NSLog("Torii: could not update the matching still: %@", error.localizedDescription) }
                self.settings = updated
                if updated.lockScreenSlotID != nil, !self.sessionLocked { LockScreenInstaller.reload(includeAgent: true) }
                self.controller?.update(settings: updated)
                self.showPanel()
                VideoImporter.removePreviousMedia(previous, keeping: updated)
            } catch {
                if let preparedImport { try? FileManager.default.removeItem(at: preparedImport.directory) }
                self.showError(error.localizedDescription)
            }
            self.importing = false
            self.importButton?.isEnabled = true
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
        loginCheckbox?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showPanel() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { updateState(); return }
        let viewController = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 464))
        viewController.view = root
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
        ])
        let poster = NSImageView()
        let posterURL = settings?.posterPath.map { URL(fileURLWithPath: $0) } ?? WallpaperSettings.posterURL
        if let source = CGImageSourceCreateWithURL(posterURL as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 800,
                kCGImageSourceShouldCacheImmediately: true,
           ] as CFDictionary) {
            poster.image = NSImage(cgImage: image, size: .zero)
        }
        poster.imageScaling = .scaleProportionallyUpOrDown
        poster.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        poster.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        poster.wantsLayer = true
        poster.layer?.cornerRadius = 8
        poster.layer?.masksToBounds = true
        poster.setAccessibilityLabel("Current wallpaper preview")
        stack.addArrangedSubview(poster)
        poster.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        poster.heightAnchor.constraint(equalToConstant: 196).isActive = true
        let caption = NSStackView()
        caption.orientation = .vertical
        caption.alignment = .leading
        caption.spacing = 4
        let heading = NSTextField(labelWithString: displayTitle)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        heading.maximumNumberOfLines = 1
        heading.widthAnchor.constraint(lessThanOrEqualToConstant: 348).isActive = true
        caption.addArrangedSubview(heading)
        let state = NSTextField(labelWithString: controller?.state ?? "Starting")
        state.font = .systemFont(ofSize: 12)
        state.textColor = .secondaryLabelColor
        stateLabel = state
        caption.addArrangedSubview(state)
        stack.addArrangedSubview(caption)
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 12
        let pause = NSButton(title: "Pause", target: self, action: #selector(togglePause))
        pause.bezelStyle = .rounded
        pauseButton = pause
        controls.addArrangedSubview(pause)
        let importVideo = NSButton(title: "Import Video…", target: self, action: #selector(importVideo))
        importVideo.bezelStyle = .rounded
        importVideo.isEnabled = !importing
        importButton = importVideo
        controls.addArrangedSubview(importVideo)
        stack.addArrangedSubview(controls)
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let preferences = NSStackView()
        preferences.orientation = .vertical
        preferences.alignment = .leading
        preferences.spacing = 7
        let coverage = NSButton(checkboxWithTitle: "Pause when the desktop is covered", target: self,
                                action: #selector(toggleCoveragePause(_:)))
        coverage.state = settings?.pauseWhenCovered == false ? .off : .on
        coverageCheckbox = coverage
        preferences.addArrangedSubview(coverage)
        let lockScreen = NSButton(checkboxWithTitle: "Animate lock screen", target: self, action: #selector(toggleLockScreen(_:)))
        lockScreen.state = settings?.lockScreenSlotID != nil ? .on : .off
        lockScreen.isEnabled = !lockScreenBusy
        lockScreenCheckbox = lockScreen
        preferences.addArrangedSubview(lockScreen)
        let login = NSButton(checkboxWithTitle: "Start at login", target: self, action: #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginCheckbox = login
        preferences.addArrangedSubview(login)
        stack.addArrangedSubview(preferences)
        let footer = NSStackView()
        footer.orientation = .horizontal
        let spacer = NSView()
        footer.addArrangedSubview(spacer)
        let quit = NSButton(title: "Quit Torii", target: self, action: #selector(quit))
        quit.isBordered = false
        quit.font = .systemFont(ofSize: 12)
        footer.addArrangedSubview(quit)
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        popover.contentViewController = viewController
        popover.contentSize = root.frame.size
        updateState()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        stateLabel = nil
        pauseButton = nil
        importButton = nil
        coverageCheckbox = nil
        lockScreenCheckbox = nil
        loginCheckbox = nil
        releaseTemporaryMemory()
    }

    private func releaseTemporaryMemory() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { malloc_zone_pressure_relief(nil, 0) }
    }

    private var displayTitle: String {
        guard let title = settings?.title else { return "Torii" }
        return title.replacingOccurrences(of: "mylivewallpapers.com-", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }

    private func updateState() {
        stateLabel?.stringValue = importing ? "Importing…" : lockScreenBusy ? "Preparing lock screen…" : controller?.state ?? "Starting"
        importButton?.isEnabled = !importing && !lockScreenBusy
        lockScreenCheckbox?.isEnabled = !importing && !lockScreenBusy
        pauseButton?.title = controller?.userPaused == true ? "Resume" : "Pause"
        statusItem?.button?.appearsDisabled = controller?.userPaused == true
        writeDiagnostics()
    }

    private func writeDiagnostics() {
        guard var diagnostics = controller?.diagnostics() else { return }
        diagnostics["lock_screen"] = ["enabled": settings?.lockScreenSlotID != nil,
                                      "busy": lockScreenBusy, "slot_id": settings?.lockScreenSlotID ?? "",
                                      "error": lockScreenError]
        guard let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: WallpaperSettings.supportURL.appendingPathComponent("status.json"), options: .atomic)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Torii"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        popover.performClose(nil)
        rendererRefresh?.cancel()
        for token in lockObservers { DistributedNotificationCenter.default().removeObserver(token) }
        if let commandObserver { DistributedNotificationCenter.default().removeObserver(commandObserver) }
    }
}
