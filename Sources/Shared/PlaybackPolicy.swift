import Foundation

struct PlaybackPolicy {
    var userPaused = false
    var sessionInactive = false
    var screenSleeping = false
    var screenSaverActive = false
    var lowPowerMode = false

    var pauseReason: String? {
        if userPaused { return "Paused" }
        if sessionInactive { return "Session locked" }
        if screenSleeping { return "Display asleep" }
        if screenSaverActive { return "Screen saver active" }
        if lowPowerMode { return "Low Power Mode" }
        return nil
    }

    var shouldPlay: Bool { pauseReason == nil }
}
