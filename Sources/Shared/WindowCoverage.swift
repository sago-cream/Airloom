import Foundation
import CoreGraphics

enum WindowCoverage {
    /// Subtract opaque rectangles without double-counting overlaps.
    static func isCovered(_ desktop: CGRect, by windows: [CGRect]) -> Bool {
        guard desktop.width > 0, desktop.height > 0 else { return false }
        var remaining = [desktop]
        for window in windows {
            remaining = remaining.flatMap { rectangle -> [CGRect] in
                let overlap = rectangle.intersection(window)
                guard !overlap.isNull, !overlap.isEmpty else { return [rectangle] }
                return [
                    CGRect(x: rectangle.minX, y: rectangle.minY, width: rectangle.width, height: overlap.minY - rectangle.minY),
                    CGRect(x: rectangle.minX, y: overlap.maxY, width: rectangle.width, height: rectangle.maxY - overlap.maxY),
                    CGRect(x: rectangle.minX, y: overlap.minY, width: overlap.minX - rectangle.minX, height: overlap.height),
                    CGRect(x: overlap.maxX, y: overlap.minY, width: rectangle.maxX - overlap.maxX, height: overlap.height),
                ].filter { $0.width > 0 && $0.height > 0 }
            }
            if remaining.isEmpty { return true }
        }
        let uncoveredArea = remaining.reduce(0) { $0 + $1.width * $1.height }
        // Ignore thin resize borders and rounded corners around an otherwise covered desktop.
        return uncoveredArea / (desktop.width * desktop.height) < 0.005
    }
}
