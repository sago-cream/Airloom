import Foundation

struct PlaybackTimeline {
    var mediaSeconds: Double
    var hostSeconds: Double
    var rate: Double
    var duration: Double

    func position(at host: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let elapsed = max(0, host - hostSeconds)
        let position = max(0, mediaSeconds + elapsed * rate)
        return position.truncatingRemainder(dividingBy: duration)
    }
}
