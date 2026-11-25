import AppKit
import SwiftUI

/// Manages the native `AgentPaneView` overlay attached to a `TerminalSurface`'s host view.
@MainActor
final class AgentPaneOverlayController {
    struct Configuration {
        let agent: AgentBridge?
        let surface: PaneSurface
        let focused: Bool
        let onFocus: () -> Void
    }

    let focus = AgentPaneFocus()
    private weak var displayedAgent: AgentBridge?
    private var overlay: NSHostingView<AgentPaneView>?
    private var forceFocusRestore = false

    func reattach(in host: NSView, above scroll: SurfaceScrollView) {
        if let overlay, host.subviews.last !== overlay {
            host.addSubview(overlay, positioned: .above, relativeTo: scroll)
        }
    }

    func syncFocus(in host: NSView, scroll: SurfaceScrollView?) {
        guard let scroll, scroll.superview === host else { return }
        let showsAgent = overlay != nil
        scroll.suppressesDocumentCursor = showsAgent
        (scroll.surfaceView as? GhosttyTerminalNSView)?.agentPaneFocus = showsAgent ? focus : nil
    }

    func update(
        in host: NSView,
        scroll: SurfaceScrollView,
        terminal: GhosttyTerminalNSView,
        configuration: Configuration
    ) {
        let agent = configuration.agent
        let surface = configuration.surface
        focus.onFocus = configuration.onFocus
        if displayedAgent !== agent || (agent == nil && overlay != nil) {
            let responder = host.window?.firstResponder as? NSView
            let focusedOverlay = overlay.map { responder?.isDescendant(of: $0) == true } ?? false
            let opensFromTerminal = agent != nil && (responder == nil || responder is GhosttyTerminalNSView)
            let forcedFocusRestore = forceFocusRestore
            forceFocusRestore = false
            let restoresFocus = configuration.focused && host.window?.isKeyWindow == true
                && (forcedFocusRestore || responder === terminal || focusedOverlay || opensFromTerminal)
            overlay?.removeFromSuperview()
            overlay = nil
            displayedAgent = agent
            if let agent, let windowID = surface.windowID {
                let onFocus = configuration.onFocus
                let hosting = NSHostingView(rootView: AgentPaneView(
                    bridge: agent,
                    surface: surface,
                    focus: focus,
                    showTerminal: { [weak self, weak agent] in
                        self?.forceFocusRestore = true
                        onFocus()
                        agent?.setGUIVisible(false, in: windowID)
                    },
                    closeAgent: { [weak self, weak agent, weak surface] in
                        self?.forceFocusRestore = true
                        onFocus()
                        guard let surface else { return }
                        agent?.exit(from: surface)
                    }
                ))
                hosting.frame = host.bounds
                hosting.autoresizingMask = [.width, .height]
                host.addSubview(hosting, positioned: .above, relativeTo: nil)
                overlay = hosting
            }
            if restoresFocus {
                DispatchQueue.main.async { [surface] in
                    FocusRestoration.restoreFocusWhenAttached(surface)
                }
            }
        }
        syncFocus(in: host, scroll: scroll)
    }
}
