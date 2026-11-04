import Foundation

struct WallpaperSettings: Codable {
    static let bundleID = "com.hsi.Torii"
    static let supportURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Torii", isDirectory: true)
    static let settingsURL = supportURL.appendingPathComponent("settings.json")
    static let mediaURL = supportURL.appendingPathComponent("Media/Wallpaper.mp4")
    static let posterURL = supportURL.appendingPathComponent("Media/Poster.jpg")

    var sourcePath: String
    var mediaPath: String
    var title: String
    var posterPath: String? = nil
    var pauseWhenCovered: Bool? = true
    var pauseInLowPowerMode = true
    var previousDesktopImages: [String: String] = [:]

    static func load() throws -> WallpaperSettings {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: settingsURL))
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.supportURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.settingsURL, options: .atomic)
    }
}
