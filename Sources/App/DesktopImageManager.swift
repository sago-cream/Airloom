import AppKit

enum DesktopImageManager {
    /// Keep a matching still behind the video and on the system's password-entry surface.
    static func applyPoster(settings: inout WallpaperSettings) throws {
        let poster = settings.posterPath.map { URL(fileURLWithPath: $0) } ?? WallpaperSettings.posterURL
        guard FileManager.default.isReadableFile(atPath: poster.path) else { return }
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "main"
            let current = NSWorkspace.shared.desktopImageURL(for: screen)
            if settings.previousDesktopImages[id] == nil, let current, current != poster {
                settings.previousDesktopImages[id] = current.path
            }
            if current != poster {
                try NSWorkspace.shared.setDesktopImageURL(poster, for: screen, options: [
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                    .allowClipping: true,
                ])
            }
        }
        try settings.save()
    }
}
