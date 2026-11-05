import AppKit
import AVFoundation
import ScreenSaver

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let path = URL(fileURLWithPath: CommandLine.arguments[1])
let bundle = Bundle(url: path)!
try bundle.loadAndReturnError()
guard let viewClass = bundle.principalClass as? ScreenSaverView.Type,
      let saver = viewClass.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360), isPreview: true)
else { fatalError("Screen saver principal class did not load") }
let window = NSWindow(contentRect: saver.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Airloom Screen Saver Test"
window.contentView = saver
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
saver.startAnimation()

func players(in layer: CALayer?) -> [AVPlayer] {
    guard let layer else { return [] }
    let own = (layer as? AVPlayerLayer)?.player.map { [$0] } ?? []
    return own + (layer.sublayers ?? []).flatMap { players(in: $0) }
}

var observations: [Double] = []
let started = Date()
var timer: Timer?
timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    let current = players(in: saver.layer)
    guard current.count == 1, let player = current.first,
          player.currentItem?.status == .readyToPlay, player.rate == 1
    else { fatalError("The real screen saver is not playing") }
    observations.append(player.currentTime().seconds)
    if Date().timeIntervalSince(started) >= 46 {
        timer?.invalidate()
        guard zip(observations, observations.dropFirst()).contains(where: { $0 > $1 })
        else { fatalError("Screen-saver video did not loop") }
        saver.stopAnimation()
        guard players(in: saver.layer).isEmpty, saver.subviews.isEmpty else {
            fatalError("Stopping the screen saver retained playback resources")
        }
        print("System screen-saver bundle passed: real playback, looping, and complete teardown")
        app.terminate(nil)
    }
}
app.run()
