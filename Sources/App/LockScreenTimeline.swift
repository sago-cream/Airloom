import AVFoundation
import Darwin

/// Samples the system renderer during a lock, with an unlock fallback for very short locks.
/// There is no persistent helper or polling timer.
enum LockScreenTimeline {
    static func resolve(media: URL) async -> PlaybackTimeline? {
        let asset = AVURLAsset(url: media)
        defer { asset.cancelLoading() }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let range = try? await track.load(.timeRange) else { return nil }
        guard let pids = run("/usr/bin/pgrep", ["-u", String(getuid()), "-x", "WallpaperAerialsExtension"])?
            .split(whereSeparator: \.isNewline).compactMap({ Int($0) }), !pids.isEmpty else { return nil }
        let predicate = "processIdentifier IN {\(pids.map(String.init).joined(separator: ","))} AND eventMessage CONTAINS \"layer time:\""
        guard let output = run("/usr/bin/log", ["show", "--last", "12s", "--style", "compact", "--predicate", predicate]) else { return nil }
        return parse(output, duration: range.duration.seconds,
                     now: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
    }

    static func parse(_ output: String, duration: Double, now: Double) -> PlaybackTimeline? {
        guard duration.isFinite, duration > 0,
              let pattern = try? NSRegularExpression(pattern: #"timebase rate: ([0-9.]+), layer time: ([0-9.]+) s, host: ([0-9.]+) s"#) else { return nil }
        let matches = pattern.matches(in: output, range: NSRange(output.startIndex..., in: output))
        let clocks = matches.compactMap { match -> PlaybackTimeline? in
            let values = (1...3).compactMap { field -> Double? in
                guard let range = Range(match.range(at: field), in: output) else { return nil }
                return Double(output[range])
            }
            guard values.count == 3, values.allSatisfy(\.isFinite), (0...1).contains(values[0]),
                  now - values[2] >= -0.1, now - values[2] < 13 else { return nil }
            return PlaybackTimeline(mediaSeconds: values[1], hostSeconds: values[2], rate: values[0], duration: duration)
        }
        // macOS creates a new video timeline for the lock screen while its older desktop
        // timeline can keep logging too. Select the newest playback epoch, not the last log line.
        return (clocks.filter { $0.mediaSeconds > 0 }.max {
            $0.hostSeconds - $0.mediaSeconds < $1.hostSeconds - $1.mediaSeconds
        })
            ?? clocks.max { $0.hostSeconds < $1.hostSeconds }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
            defer { timeout.cancel() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }
}
