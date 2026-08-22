import AppKit
import SwiftUI

/// Borderless key-capable panel — replaces NSPopover so the surface is entirely ours
/// (no system arrow, no vibrancy material).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PanelController: NSObject, NSWindowDelegate {
    static let shared = PanelController()

    private var panel: KeyPanel?
    private var hosting: NSHostingView<PanelView>?
    private var globalMonitor: Any?

    var isShown: Bool { panel?.isVisible ?? false }

    // MARK: - Lifecycle

    private func makePanel() -> KeyPanel {
        let view = NSHostingView(rootView: PanelView())
        hosting = view

        let p = KeyPanel(contentRect: .zero,
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered,
                         defer: false)
        p.contentView = view
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.animationBehavior = .utilityWindow
        p.delegate = self
        return p
    }

    func toggle(from button: NSStatusBarButton) {
        isShown ? hide() : show(from: button)
    }

    func show(from button: NSStatusBarButton) {
        let p = panel ?? makePanel()
        panel = p

        // Size to the SwiftUI content, then park it under the status item.
        let size = hosting?.fittingSize ?? NSSize(width: 344, height: 520)
        guard let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = anchor.minY - size.height - 6

        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.makeKey()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
            p.animator().alphaValue = 1
        }

        installMonitor()
    }

    /// Re-sizes an already-open panel to its content, keeping the top edge pinned under the
    /// status item. The update strip appearing or being dismissed is what needs this.
    func refit() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let p = self.panel, p.isVisible, let hosting = self.hosting else { return }
            let size = hosting.fittingSize
            guard size.height > 1, abs(size.height - p.frame.height) > 0.5 else { return }
            let top = p.frame.maxY
            p.setFrame(NSRect(x: p.frame.minX, y: top - size.height,
                              width: p.frame.width, height: size.height),
                       display: true, animate: false)
        }
    }

    func hide() {
        removeMonitor()
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    // MARK: - Dismissal

    private func installMonitor() {
        removeMonitor()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeMonitor() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
