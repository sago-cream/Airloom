import AppKit

let arguments = CommandLine.arguments
let commands = ["--pause": "pause", "--resume": "resume", "--snapshot": "snapshot", "--quit": "quit",
                "--continuous-playback": "continuous", "--efficient-playback": "efficient",
                "--enable-lock-screen": "lock-screen-on", "--disable-lock-screen": "lock-screen-off"]
let existing = NSRunningApplication.runningApplications(withBundleIdentifier: WallpaperSettings.bundleID)
    .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if existing {
    let command = commands.first { arguments.contains($0.key) }?.value ?? "show"
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.hsi.Torii.command"), object: nil,
        userInfo: ["command": command], deliverImmediately: true
    )
} else if commands.keys.contains(where: arguments.contains) {
    fputs("Torii is not running.\n", stderr)
    exit(1)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
