import AppKit
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: DesktopController?
    private var statusItem: NSStatusItem?
    private var detailsWindow: NSWindow?
    private var stateLabel: NSTextField?
    private var pauseButton: NSButton?
    private var commandObserver: NSObjectProtocol?
    private var settings: WallpaperSettings?
    private var importing = false
    private var importButton: NSButton?
    private var coverageCheckbox: NSButton?

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
        controller = DesktopController(settings: loaded)
        controller?.onStateChange = { [weak self] in self?.updateState() }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "mountain.2", accessibilityDescription: "Torii wallpaper")
        item.button?.toolTip = "Torii — \(loaded.title)"
        item.menu = makeMenu()
        statusItem = item
        commandObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.hsi.Torii.command"), object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            switch notification.userInfo?["command"] as? String {
            case "pause": self.controller?.setPaused(true)
            case "resume": self.controller?.setPaused(false)
            case "show": self.showDetails()
            case "snapshot": self.writeDiagnostics()
            case "quit": NSApp.terminate(nil)
            case "continuous": self.setCoveragePause(false)
            case "efficient": self.setCoveragePause(true)
            default: break
            }
        }
        writeDiagnostics()
        if CommandLine.arguments.contains("--show") { showDetails() }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Torii", action: #selector(showDetails), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Pause Wallpaper", action: #selector(togglePause), keyEquivalent: "p")
        menu.addItem(withTitle: "Import Video…", action: #selector(importVideo), keyEquivalent: "o")
        menu.addItem(withTitle: "Screen Saver Settings…", action: #selector(openScreenSaverSettings), keyEquivalent: "")
        menu.addItem(withTitle: "Open Wallpaper Folder", action: #selector(openFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Torii", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first { $0.action == #selector(importVideo) }?.isEnabled = !importing
        menu.items.first { $0.action == #selector(togglePause) }?.title =
            controller?.userPaused == true ? "Resume Wallpaper" : "Pause Wallpaper"
        menu.items.first { $0.action == #selector(toggleLogin) }?.state =
            SMAppService.mainApp.status == .enabled ? .on : .off
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

    @objc private func importVideo() {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Wallpaper Video"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/wallpaper")
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
                do { try DesktopImageManager.applyPoster(settings: &updated) }
                catch { NSLog("Torii: could not update the matching still: %@", error.localizedDescription) }
                self.settings = updated
                self.controller?.update(settings: updated)
                self.detailsWindow?.close()
                self.detailsWindow = nil
                self.showDetails()
                VideoImporter.removePreviousMedia(previous, keeping: updated)
            } catch {
                if let preparedImport { try? FileManager.default.removeItem(at: preparedImport.directory) }
                self.showError(error.localizedDescription)
            }
            self.importing = false
            self.importButton?.isEnabled = true
            self.updateState()
        }
    }

    @objc private func openFolder() {
        let source = settings.map { URL(fileURLWithPath: $0.sourcePath) }
        NSWorkspace.shared.activateFileViewerSelecting(source.map { [$0] } ?? [])
    }

    @objc private func openScreenSaverSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension?ScreenSaver") {
            NSWorkspace.shared.open(url)
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
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showDetails() {
        if let detailsWindow {
            detailsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = "Torii"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 470))
        window.contentView = root
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
        ])
        let poster = NSImageView()
        poster.image = NSImage(contentsOf: settings?.posterPath.map { URL(fileURLWithPath: $0) } ?? WallpaperSettings.posterURL)
        poster.imageScaling = .scaleProportionallyUpOrDown
        poster.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        poster.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        poster.wantsLayer = true
        poster.layer?.cornerRadius = 10
        poster.layer?.masksToBounds = true
        poster.setAccessibilityLabel("Current wallpaper preview")
        stack.addArrangedSubview(poster)
        poster.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        poster.heightAnchor.constraint(equalToConstant: 245).isActive = true
        let heading = NSTextField(labelWithString: displayTitle)
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        heading.maximumNumberOfLines = 1
        heading.widthAnchor.constraint(lessThanOrEqualToConstant: 512).isActive = true
        stack.addArrangedSubview(heading)
        let state = NSTextField(labelWithString: controller?.state ?? "Starting")
        state.font = .systemFont(ofSize: 13)
        state.textColor = .secondaryLabelColor
        stateLabel = state
        stack.addArrangedSubview(state)
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
        let saver = NSButton(title: "Screen Saver…", target: self, action: #selector(openScreenSaverSettings))
        saver.bezelStyle = .rounded
        controls.addArrangedSubview(saver)
        stack.addArrangedSubview(controls)
        let coverage = NSButton(checkboxWithTitle: "Pause when the desktop is covered", target: self,
                                action: #selector(toggleCoveragePause(_:)))
        coverage.state = settings?.pauseWhenCovered == false ? .off : .on
        coverageCheckbox = coverage
        stack.addArrangedSubview(coverage)
        detailsWindow = window
        updateState()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var displayTitle: String {
        guard let title = settings?.title else { return "Torii" }
        return title.replacingOccurrences(of: "mylivewallpapers.com-", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }

    private func updateState() {
        stateLabel?.stringValue = controller?.state ?? "Starting"
        pauseButton?.title = controller?.userPaused == true ? "Resume" : "Pause"
        statusItem?.button?.appearsDisabled = controller?.userPaused == true
        writeDiagnostics()
    }

    private func writeDiagnostics() {
        guard let diagnostics = controller?.diagnostics(),
              let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
        else { return }
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
        if let commandObserver { DistributedNotificationCenter.default().removeObserver(commandObserver) }
    }
}
