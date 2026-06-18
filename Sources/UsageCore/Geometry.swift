import AppKit

public enum WindowSide { case left, right }

/// Pure coordinate computation for auxiliary window placement — extracted so
/// this logic can be unit-tested without a live screen or real NSWindow.
///
/// Given the popover/button anchor frame, which side to open on, and the
/// screen's visible frame for clamping, returns the x-coordinate to pass to
/// `window.setFrameTopLeftPoint`. Does not touch NSWindow or NSScreen itself.
public func targetWindowX(
    windowWidth: CGFloat,
    anchorFrame: NSRect,
    side: WindowSide,
    screenVisibleFrame: NSRect
) -> CGFloat {
    let gap: CGFloat = 14
    var x: CGFloat
    switch side {
    case .left:  x = anchorFrame.minX - windowWidth - gap
    case .right: x = anchorFrame.maxX + gap
    }
    return min(max(x, screenVisibleFrame.minX), screenVisibleFrame.maxX - windowWidth)
}
