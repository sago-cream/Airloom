import AppKit

enum StatusMenu {
    static func present(_ menu: NSMenu, from button: NSStatusBarButton, event openingEvent: NSEvent? = NSApp.currentEvent) {
        guard let window = button.window else { return }
        let event = openingEvent.flatMap { event -> NSEvent? in
            guard [.leftMouseDown, .rightMouseDown].contains(event.type), event.window === window,
                  button.bounds.contains(button.convert(event.locationInWindow, from: nil)) else { return nil }
            return event
        } ?? NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.minY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )
        guard let event else { return }
        // One tracking session owns the opening press and consumes dismissal
        // clicks. The status button acts on mouse-down, so mouse-up cannot reopen it.
        button.highlight(true)
        defer { button.highlight(false) }
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }
}
