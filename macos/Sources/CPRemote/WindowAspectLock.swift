// Keeps the app window at the front panel's proportions and hides its title
// bar, so the panel's own edges are the window's edges.

import AppKit
import SwiftUI

/// Makes the window the processor itself: no title bar, no buttons, no
/// background, so the panel's own edges are the window's edges and it looks
/// set into the desktop. It keeps the panel's proportions, and it is moved by
/// dragging the panel.
struct WindowAspectLock: NSViewRepresentable {
    let aspect: CGFloat

    /// The aspect last applied to the window; nil before the first.
    @MainActor final class Coordinator {
        var appliedAspect: CGFloat?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let applied = context.coordinator
        DispatchQueue.main.async { apply(to: view, applied) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The panel changes shape with the processor model: follow it. Any
        // other update (a poll, a fader move) leaves the window alone, so a
        // size the user chose is kept.
        let applied = context.coordinator
        guard applied.appliedAspect != aspect else { return }
        DispatchQueue.main.async { apply(to: nsView, applied) }
    }

    private func apply(to view: NSView, _ applied: Coordinator) {
        // Not in a window yet: the next update tries again.
        guard let window = view.window, applied.appliedAspect != aspect else { return }
        let first = applied.appliedAspect == nil
        applied.appliedAspect = aspect
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        // The window opens at least 1100 wide; on a model change it keeps the
        // user's width (never below the panel's 900 minimum) and takes the
        // new shape.
        let width = max(window.frame.width, first ? 1100 : 900)
        window.setContentSize(NSSize(width: width, height: width / aspect))
        guard first else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
    }
}
