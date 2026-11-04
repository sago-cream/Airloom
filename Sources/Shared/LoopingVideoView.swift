import AppKit
import AVFoundation

/// AVFoundation owns decoding and presentation; there is no application frame timer.
final class LoopingVideoView: NSView {
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var itemObservation: NSKeyValueObservation?
    private(set) var failure: String?
    var onFailure: (() -> Void)?
    private var wantsPlayback = true
    private var resumeTarget: CMTime?
    private var seeking = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The desktop's matching system wallpaper stays visible before decoding starts.
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { nil }

    func load(url: URL, resumeAt seconds: Double = 0) {
        unload()
        if seconds.isFinite, seconds > 0 { resumeTarget = CMTime(seconds: seconds, preferredTimescale: 600) }
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
        videoLayer.frame = bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(videoLayer)
        playerLayer = videoLayer
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
        if wantsPlayback, resumeTarget == nil { queue.play() }
    }

    func setPlaying(_ playing: Bool) {
        wantsPlayback = playing
        if playing {
            restorePositionIfReady()
            if resumeTarget == nil, !seeking { player?.play() }
        } else { player?.pause() }
    }

    private func restorePositionIfReady() {
        guard let target = resumeTarget, let player, player.currentItem?.status == .readyToPlay else { return }
        resumeTarget = nil
        seeking = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
            DispatchQueue.main.async {
                guard let self, let player, self.player === player else { return }
                self.seeking = false
                if self.wantsPlayback { player.play() }
            }
        }
    }

    func unload() {
        itemObservation?.invalidate()
        itemObservation = nil
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
        failure = nil
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
        player?.pause()
        looper?.disableLooping()
        playerLayer?.player = nil
        player?.removeAllItems()
    }
}
