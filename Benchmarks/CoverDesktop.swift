import AppKit

// A normal, maximized window (not a full-screen Space), used to compare covered playback.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSScreen.main!.visibleFrame,
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.setFrame(NSScreen.main!.visibleFrame, display: true)
window.title = "Torii performance measurement"
window.isReleasedWhenClosed = false
let label = NSTextField(wrappingLabelWithString:
    "Measuring wallpaper use behind a maximized window.\nClose this window to stop covering the desktop.")
label.font = .systemFont(ofSize: 22, weight: .medium)
label.alignment = .center
label.translatesAutoresizingMaskIntoConstraints = false
window.contentView!.addSubview(label)
NSLayoutConstraint.activate([
    label.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
    label.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
    label.widthAnchor.constraint(equalToConstant: 640),
])
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
