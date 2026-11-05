import AppKit
import ScreenSaver

@objc(ToriiScreenSaver)
final class ToriiScreenSaver: ScreenSaverView {
    private var video: LoopingVideoView?
    private var changeObserver: NSObjectProtocol?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        // The video layer presents at the source frame rate. The framework timer does no drawing.
        animationTimeInterval = 60
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        changeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.hsi.Torii.wallpaperChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.video != nil else { return }
            self.releaseVideo()
            self.startVideo()
        }
    }

    required init?(coder: NSCoder) { nil }

    override func startAnimation() {
        super.startAnimation()
        startVideo()
    }

    private func startVideo() {
        guard video == nil else { return }
        let configured = (try? WallpaperSettings.load()).map { URL(fileURLWithPath: $0.mediaPath) }
        let bundled = Bundle(for: ToriiScreenSaver.self).url(forResource: "Wallpaper", withExtension: "mp4")
        guard let url = configured.flatMap({ FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil }) ?? bundled else { return }
        let view = LoopingVideoView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        view.load(url: url)
        video = view
    }

    override func stopAnimation() {
        releaseVideo()
        super.stopAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { releaseVideo() }
    }

    override func animateOneFrame() {}

    private func releaseVideo() {
        video?.unload()
        video?.removeFromSuperview()
        video = nil
    }

    deinit {
        if let changeObserver { DistributedNotificationCenter.default().removeObserver(changeObserver) }
    }
}
