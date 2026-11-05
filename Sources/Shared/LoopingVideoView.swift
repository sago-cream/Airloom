import AppKit
import AVFoundation
import ImageIO

/// AVFoundation owns decoding and presentation; there is no application frame timer.
final class LoopingVideoView: NSView {
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var itemObservation: NSKeyValueObservation?
    private var displayObservation: NSKeyValueObservation?
    private(set) var failure: String?
    var onFailure: (() -> Void)?
    var onPresentationReady: (() -> Void)?
    private var wantsPlayback = true
    private var resumeTarget: CMTime?
    private var seeking = false
    private var prepared = false
    private(set) var presented = false
    private(set) var timelineError: Double?
    var fadeInDuration: Double = 0
    private var resumeTimeline: PlaybackTimeline?
    private var presentationDeadline: Double?
    private var presentationScheduled = false
    private var mediaURL: URL?
    private var placeholder: CGImage?
    private var stillGenerator: AVAssetImageGenerator?
    private var stillTask: Task<Void, Never>?
    private(set) var stillPreparing = false
    var hasPlaceholder: Bool { placeholder != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    func load(url: URL, resumeAt seconds: Double = 0, timeline: PlaybackTimeline? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let still = placeholder
        unload()
        setPlaceholder(still)
        CATransaction.commit()
        mediaURL = url
        resumeTimeline = timeline
        resumeTarget = CMTime(seconds: seconds.isFinite ? max(0, seconds) : 0, preferredTimescale: 600)
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.volume = 0
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.automaticallyWaitsToMinimizeStalling = false
        let videoLayer = AVPlayerLayer(player: queue)
        videoLayer.videoGravity = .resizeAspectFill
        videoLayer.isOpaque = true
        videoLayer.opacity = 0
        videoLayer.frame = bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(videoLayer)
        playerLayer = videoLayer
        displayObservation = videoLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.presentIfReady() }
        }
        player = queue
        looper = AVPlayerLooper(player: queue, templateItem: item)
        // Observe a real queue item: AVPlayerLooper plays replicas of the template.
        itemObservation = queue.observe(\.currentItem?.status, options: [.new]) { [weak self] queue, _ in
            DispatchQueue.main.async {
                guard let self, self.player === queue else { return }
                if queue.currentItem?.status == .failed {
                    self.failure = queue.currentItem?.error?.localizedDescription ?? "Video playback failed."
                    self.onFailure?()
                } else { self.restorePositionIfReady() }
            }
        }
        restorePositionIfReady()
    }

    func setPlaying(_ playing: Bool) {
        wantsPlayback = playing
        if playing {
            restorePositionIfReady()
            presentIfReady()
        } else { player?.pause() }
    }

    private func restorePositionIfReady() {
        guard var target = resumeTarget, let player, player.currentItem?.status == .readyToPlay else { return }
        if let resumeTimeline {
            let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.12
            target = CMTime(seconds: resumeTimeline.position(at: host), preferredTimescale: 60000)
            presentationDeadline = host
        }
        resumeTarget = nil
        seeking = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            DispatchQueue.main.async {
                guard let self, let player, self.player === player else { return }
                guard finished else { return }
                player.preroll(atRate: 1) { [weak self, weak player] ready in
                    DispatchQueue.main.async {
                        guard let self, let player, self.player === player, ready else { return }
                        self.seeking = false
                        self.prepared = true
                        self.presentIfReady()
                    }
                }
            }
        }
    }

    private func presentIfReady() {
        guard prepared, !seeking, let playerLayer, playerLayer.isReadyForDisplay else { return }
        if let deadline = presentationDeadline {
            let remaining = deadline - CMClockGetTime(CMClockGetHostTimeClock()).seconds
            if remaining > 0 {
                guard !presentationScheduled else { return }
                presentationScheduled = true
                let currentPlayer = player
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self, weak currentPlayer] in
                    guard let self, let currentPlayer, self.player === currentPlayer else { return }
                    self.presentationScheduled = false
                    self.presentIfReady()
                }
                return
            }
        }
        if !presented {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.opacity = 1
            if fadeInDuration > 0 {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = fadeInDuration
                playerLayer.add(fade, forKey: "handoff")
            }
            CATransaction.commit()
            presented = true
            if let resumeTimeline, let actual = player?.currentTime().seconds {
                let expected = resumeTimeline.position(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
                let delta = abs(actual - expected)
                timelineError = min(delta, abs(resumeTimeline.duration - delta))
            }
            onPresentationReady?()
        }
        if wantsPlayback { player?.play() }
    }

    static func placeholder(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    func setPlaceholder(_ image: CGImage?) {
        placeholder = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    func unload(preserveFrame: Bool = false) {
        stillTask?.cancel()
        stillTask = nil
        stillGenerator?.cancelAllCGImageGeneration()
        stillGenerator = nil
        stillPreparing = false
        let savedURL = mediaURL
        let savedTime = player?.currentTime()
        itemObservation?.invalidate()
        itemObservation = nil
        displayObservation?.invalidate()
        displayObservation = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        resumeTarget = nil
        seeking = false
        prepared = false
        presented = false
        timelineError = nil
        resumeTimeline = nil
        presentationDeadline = nil
        presentationScheduled = false
        failure = nil
        if preserveFrame, let savedURL, let savedTime, savedTime.isNumeric {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: savedURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            stillGenerator = generator
            stillPreparing = true
            stillTask = Task { @MainActor [weak self] in
                let frame = try? await generator.image(at: savedTime)
                guard let self, !Task.isCancelled, self.stillGenerator === generator else { return }
                if let frame { self.setPlaceholder(frame.image) }
                self.stillPreparing = false
                self.stillGenerator = nil
                self.stillTask = nil
            }
        } else if !preserveFrame { setPlaceholder(nil) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }

    deinit {
        stillTask?.cancel()
        stillGenerator?.cancelAllCGImageGeneration()
        itemObservation?.invalidate()
        displayObservation?.invalidate()
        player?.pause()
        looper?.disableLooping()
        playerLayer?.player = nil
        player?.removeAllItems()
    }
}
