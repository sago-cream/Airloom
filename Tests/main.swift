import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

var policy = PlaybackPolicy()
expect(policy.shouldPlay, "A fresh session should play")
policy.sessionInactive = true
expect(!policy.shouldPlay, "A locked session must stop desktop decoding")
policy.screenSaverActive = true
policy.sessionInactive = false
expect(!policy.shouldPlay, "Unlocking must not resume underneath an active screen saver")
policy.screenSaverActive = false
policy.screenSleeping = true
expect(!policy.shouldPlay, "Sleeping displays must not decode")
policy.screenSleeping = false
policy.userPaused = true
policy.lowPowerMode = true
expect(policy.pauseReason == "Paused", "The user's pause must survive power changes")
policy.lowPowerMode = false
expect(!policy.shouldPlay, "Leaving Low Power Mode must preserve manual pause")
policy.userPaused = false
expect(policy.shouldPlay, "Resume only after every pause condition clears")
let settings = WallpaperSettings(sourcePath: "/a b/input.mp4", mediaPath: "/a b/video.mp4", title: "Video")
let roundTrip = try JSONDecoder().decode(WallpaperSettings.self, from: JSONEncoder().encode(settings))
expect(roundTrip.sourcePath == settings.sourcePath, "File paths must round trip intact")
print("Playback policy and settings tests passed")
