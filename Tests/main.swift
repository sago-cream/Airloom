import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

var policy = PlaybackPolicy()
expect(policy.shouldPlay, "A fresh session should play")
policy.sessionInactive = true
expect(!policy.shouldPlay, "The foreground policy must report a locked session")
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
var warm = PlaybackPolicy()
warm.sessionInactive = true
expect(warm.shouldAnimate(visible: false, nativeLockScreen: true), "Native-lock mode prepares playback behind authentication")
expect(!warm.shouldAnimate(visible: false, nativeLockScreen: false), "Without native lock playback the desktop stays paused")
warm.screenSleeping = true
expect(!warm.shouldAnimate(visible: false, nativeLockScreen: true), "Sleep stops decoding even during a lock")
warm.screenSleeping = false
warm.userPaused = true
expect(!warm.shouldAnimate(visible: true, nativeLockScreen: true), "Manual pause overrides lock preparation")
warm.userPaused = false
warm.lowPowerMode = true
expect(!warm.shouldAnimate(visible: true, nativeLockScreen: true), "Low Power Mode overrides lock preparation")
warm.lowPowerMode = false
warm.sessionInactive = false
expect(!warm.shouldAnimate(visible: false, nativeLockScreen: true), "Covered playback pauses")
expect(warm.shouldAnimate(visible: false, nativeLockScreen: true, unlockGrace: true), "Unlock keeps playback through the login-window fade")
let settings = WallpaperSettings(sourcePath: "/a b/input.mp4", mediaPath: "/a b/video.mp4", title: "Video")
let roundTrip = try JSONDecoder().decode(WallpaperSettings.self, from: JSONEncoder().encode(settings))
expect(roundTrip.sourcePath == settings.sourcePath, "File paths must round trip intact")
print("Playback policy and settings tests passed")
let desktop = CGRect(x: 0, y: 0, width: 1000, height: 800)
expect(WindowCoverage.isCovered(desktop, by: [desktop]), "A maximized window covers the desktop")
expect(!WindowCoverage.isCovered(desktop, by: []), "An empty desktop must animate")
expect(!WindowCoverage.isCovered(desktop, by: [CGRect(x: 0, y: 0, width: 500, height: 800)]), "Partial coverage must keep animation")
expect(WindowCoverage.isCovered(desktop, by: [
    CGRect(x: 0, y: 0, width: 600, height: 800), CGRect(x: 500, y: 0, width: 500, height: 800)
]), "Tiled overlapping windows cover the desktop")
expect(!WindowCoverage.isCovered(desktop, by: [
    CGRect(x: 0, y: 0, width: 700, height: 800), CGRect(x: 0, y: 0, width: 700, height: 800)
]), "Overlaps must not double-count coverage")
expect(!WindowCoverage.isCovered(desktop, by: [CGRect(x: 0, y: 0, width: 1000, height: 700)]), "A visible strip must keep animation")
print("Window coverage tests passed")
let before: [String: Any] = ["SystemDefault": ["Type": "original"], "AllSpacesAndDisplays": "$null",
    "Displays": ["display": ["Type": "original"]], "Spaces": ["space": ["Default": ["Type": "original"],
    "Displays": ["display": ["Type": "original"]], "keep": "space metadata"]], "unknown": "preserve"]
let slot = "C7AD3D0A-7EDF-412C-A237-B3C9D27381A1"
let selected = try AerialConfiguration.selecting(slot, in: before)
expect(AerialConfiguration.assetID(in: selected["SystemDefault"]) == slot, "The native aerial must be selected")
expect(selected["unknown"] as? String == "preserve", "Unknown wallpaper fields must survive")
let selectedSpaces = selected["Spaces"] as! [String: [String: Any]]
expect(selectedSpaces["space"]?["keep"] as? String == "space metadata", "Space metadata must survive")
let restored = AerialConfiguration.restoring(before, in: selected, slotID: slot)
expect((restored["SystemDefault"] as? [String: String])?["Type"] == "original", "Restore must recover the previous wallpaper")
var userChanged = selected
userChanged["SystemDefault"] = ["Type": "user-selected-photo"]
let preserved = AerialConfiguration.restoring(before, in: userChanged, slotID: slot)
expect((preserved["SystemDefault"] as? [String: String])?["Type"] == "user-selected-photo", "Restore must preserve later user choices")
do {
    _ = try AerialConfiguration.selecting("../invalid", in: before)
    fatalError("Invalid asset IDs must be rejected")
} catch {}
print("Native aerial selection and selective restore tests passed")
