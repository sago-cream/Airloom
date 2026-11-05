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
    private(set) var prepared = false
    private var presentationNotified = false
    private(set) var loadGeneration = 0
    private(set) var presented = false
    private(set) var timelineError: Double?
    var fadeInDuration: Double = 0
    private var resumeTimeline: PlaybackTimeline?
    private var presentationDeadline: Double?
    private var presentationScheduled = false
    private var preparationGeneration = 0
    private var placeholder: CGImage?
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
        loadGeneration += 1
        resumeTimeline = timeline
        resumeTarget = CMTime(seconds: seconds.isFinite ? max(0, seconds) : 0, preferredTimescale: 600)
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.volume = 0
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.automaticallyWaitsToMinimizeStalling = false
        queue.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
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

    func synchronize(to timeline: PlaybackTimeline) {
        guard player != nil else { return }
        player?.pause()
        resumeTimeline = timeline
        resumeTarget = .zero
        prepared = false
        seeking = false
        presentationNotified = false
        presentationDeadline = nil
        presentationScheduled = false
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
        preparationGeneration += 1
        let generation = preparationGeneration
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            DispatchQueue.main.async {
                guard let self, let player, self.player === player, self.preparationGeneration == generation else { return }
                guard finished else { return }
                player.preroll(atRate: 1) { [weak self, weak player] ready in
                    DispatchQueue.main.async {
                        guard let self, let player, self.player === player, ready,
                              self.preparationGeneration == generation else { return }
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
                let generation = preparationGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self, weak currentPlayer] in
                    guard let self, let currentPlayer, self.player === currentPlayer,
                          self.preparationGeneration == generation else { return }
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
            setPlaceholder(nil)
        }
        if !presentationNotified {
            presentationNotified = true
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
            kCGImageSourceThumbnailMaxPixelSize: 4096,
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

    func unload() {
        preparationGeneration += 1
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
        presentationNotified = false
        setPlaceholder(nil)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }

    deinit {
        itemObservation?.invalidate()
        displayObservation?.invalidate()
        player?.pause()
        looper?.disableLooping()
        playerLayer?.player = nil
        player?.removeAllItems()
    }
}
