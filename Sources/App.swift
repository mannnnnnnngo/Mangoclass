import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontLoader.registerBundledFonts()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Redraw the title every second, and whenever the schedule changes.
        Ticker.shared.$now
            .sink { [weak self] _ in self?.refreshTitle() }
            .store(in: &cancellables)
        Store.shared.$data
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshTitle() } }
            .store(in: &cancellables)
        Updater.shared.statusPublisher
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refreshTitle() } }
            .store(in: &cancellables)

        refreshTitle()

        // Every launch asks GitHub whether there's a newer version. See Updater.swift.
        Updater.shared.startAutomaticChecks()
    }

    // MARK: - Menu bar title

    private func refreshTitle() {
        guard let button = statusItem.button else { return }
        let data = Store.shared.data
        let snap = Engine.snapshot(data: data)

        var parts: [String] = []
        if data.showDayLetterInMenuBar {
            switch snap.today.kind {
            case .rotation(let r): parts.append(r.name)
            case .special(let s):  parts.append(truncate(s.name, limit: 10))
            case .holiday, .weekend, .unscheduled: break
            }
        }

        switch snap.phase {
        case .inClass:
            if data.showClassNameInMenuBar { parts.append(truncate(snap.current?.name ?? "")) }
            parts.append(Engine.compact(snap.secondsRemaining, showSeconds: data.showSecondsInMenuBar))
        case .passing, .beforeSchool:
            let name = data.showClassNameInMenuBar ? truncate(snap.upNext?.period.name ?? "") : ""
            parts.append("→ \(name)".trimmingCharacters(in: .whitespaces))
            parts.append(Engine.compact(snap.secondsRemaining, showSeconds: data.showSecondsInMenuBar))
        case .afterSchool:
            parts.append("Done")
        case .noSchool:
            switch snap.today.kind {
            case .weekend: parts.append("No school")
            case .holiday: parts.append(truncate(snap.today.title, limit: 14))
            default: parts.append("Free day")
            }
        }

        let title = NSMutableAttributedString(
            string: parts.joined(separator: " · "),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)]
        )

        // A tinted dot on the end is the menu bar's whole share of the update notice —
        // no count, no colour in the text itself.
        if Updater.shared.status.manifest != nil {
            title.append(NSAttributedString(string: " •", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: NSColor(hex: DS.brandVioletHex)
            ]))
        }

        button.attributedTitle = title
        button.toolTip = "mangoclass \(Updater.shared.currentVersionString)"
    }

    private func truncate(_ name: String, limit: Int = 14) -> String {
        name.count <= limit ? name : String(name.prefix(limit - 1)) + "…"
    }

    // MARK: - Interaction

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            PanelController.shared.toggle(from: sender)
        }
    }

    private func showContextMenu() {
        PanelController.shared.hide()
        let menu = NSMenu()
        menu.addItem(withTitle: "Edit Schedules…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self

        menu.addItem(.separator())

        // The version, then whatever the updater currently has to offer about it.
        let version = NSMenuItem(title: "mangoclass \(Updater.shared.currentVersionString)",
                                 action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        if let pending = Updater.shared.status.manifest {
            menu.addItem(withTitle: "Update to \(pending.version)…",
                         action: #selector(updateNow), keyEquivalent: "")
                .target = self
        } else {
            menu.addItem(withTitle: "Check for Updates…",
                         action: #selector(checkForUpdates), keyEquivalent: "")
                .target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Class Schedule", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func checkForUpdates() {
        SettingsWindow.shared.show(tab: .updates)
        Updater.shared.check(userInitiated: true)
    }

    @objc private func updateNow() {
        SettingsWindow.shared.show(tab: .updates)
        Updater.shared.updateNow()
    }
}

@main
enum ClassScheduleApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
