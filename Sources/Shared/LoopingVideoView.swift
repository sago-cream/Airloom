import AppKit
import AVFoundation

/// AVFoundation owns decoding and presentation; there is no application frame timer.
final class LoopingVideoView: NSView {
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var itemObservation: NSKeyValueObservation?
    private(set) var failure: String?
    private var wantsPlayback = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { nil }

    func load(url: URL) {
        unload()
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.volume = 0
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.automaticallyWaitsToMinimizeStalling = false
        let videoLayer = AVPlayerLayer(player: queue)
        videoLayer.videoGravity = .resizeAspectFill
        videoLayer.frame = bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(videoLayer)
        playerLayer = videoLayer
        player = queue
        looper = AVPlayerLooper(player: queue, templateItem: item)
        // Observe a real queue item: AVPlayerLooper plays replicas of the template.
        itemObservation = queue.observe(\.currentItem?.status, options: [.new]) { [weak self] queue, _ in
            guard queue.currentItem?.status == .failed else { return }
            let message = queue.currentItem?.error?.localizedDescription ?? "Video playback failed."
            DispatchQueue.main.async { self?.failure = message }
        }
        if wantsPlayback { queue.play() }
    }

    func setPlaying(_ playing: Bool) {
        wantsPlayback = playing
        if playing { player?.play() } else { player?.pause() }
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
