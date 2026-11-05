import AppKit

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs(message + "\n", stderr); exit(1) }
}
final class TrackingProbe: NSObject, NSMenuDelegate {
    var opens = 0
    var closes = 0
    func menuWillOpen(_ menu: NSMenu) { opens += 1 }
    func menuDidClose(_ menu: NSMenu) { closes += 1 }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
let button = item.button!
button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Airloom menu test")
let deadline = Date().addingTimeInterval(3)
while (button.window?.frame.height ?? 0) == 0, Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
expect((button.window?.frame.height ?? 0) > 0, "Menu test requires an active macOS desktop")
let menu = NSMenu()
let probe = TrackingProbe()
menu.delegate = probe
menu.addItem(withTitle: "Airloom", action: nil, keyEquivalent: "").isEnabled = false
menu.addItem(withTitle: "Pause Wallpaper", action: nil, keyEquivalent: "")
let outsideWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 100),
                             styleMask: .borderless, backing: .buffered, defer: false)
for outside in [false, true, false, true] {
    var timedOut = false
    var inputSent = false
    let clickedWindow = outside ? outsideWindow : button.window!
    let point = outside ? NSPoint(x: 20, y: 20) : button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    let input = Timer(timeInterval: 0.2, repeats: false) { _ in
        inputSent = true
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: clickedWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            app.postEvent(event, atStart: false)
        }
    }
    let timeout = Timer(timeInterval: 2, repeats: false) { _ in
        timedOut = true
        menu.cancelTrackingWithoutAnimation()
    }
    RunLoop.main.add(input, forMode: .eventTracking)
    RunLoop.main.add(timeout, forMode: .eventTracking)
    let opening = NSEvent.mouseEvent(with: .leftMouseDown,
                                     location: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil),
                                     modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: button.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    StatusMenu.present(menu, from: button, event: opening)
    input.invalidate()
    timeout.invalidate()
    expect(inputSent && !timedOut, outside ? "Outside click did not dismiss the native menu" : "Second icon click did not dismiss the native menu")
    expect(button.cell?.isHighlighted == false, "Closed menu left the icon highlighted")
    while app.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {}
}
expect(probe.opens == 4 && probe.closes == 4, "Tracking did not end after every dismissal")
NSStatusBar.system.removeStatusItem(item)
print("Native menu passed: second icon clicks, outside clicks, repeated open/close, tracking teardown, highlight cleanup")
