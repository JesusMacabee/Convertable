import AppKit
import ConvertableCore

/// The status item: an icon that reflects state, and a menu of quick actions. Everything with real
/// surface area lives in the dashboard, which "Open Dashboard" launches in the default browser.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let controller: AppController
    private let dashboardURL: String
    private let notifier: Notifier
    private let menu = NSMenu()

    var snapshot: StatusSnapshot? { didSet { render() } }
    var batch: BatchProgress? { didSet { if snapshot != nil { render() } } }
    var serverError: String? { didSet { render() } }

    init(controller: AppController, dashboardURL: String, notifier: Notifier) {
        self.controller = controller
        self.dashboardURL = dashboardURL
        self.notifier = notifier
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        item.menu = menu
        item.button?.image = Self.icon(for: nil)
        item.button?.toolTip = "Convertable"
        render()
    }

    // MARK: Icon

    static func icon(for state: AppState?) -> NSImage? {
        let name: String
        switch state {
        case .converting: name = "arrow.triangle.2.circlepath"
        case .scanning: name = "magnifyingglass"
        case .paused: name = "pause.circle"
        case .batchComplete: name = "checkmark.circle"
        case .attention: name = "exclamationmark.triangle"
        case .volumeUnavailable: name = "externaldrive.badge.xmark"
        case .idle, .none: name = "waveform"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Convertable")
        img?.isTemplate = true
        return img
    }

    private func render() {
        guard let s = snapshot else { return }
        item.button?.image = Self.icon(for: s.state)
        var title = ""
        if let b = s.batch ?? batch, s.state == .converting, b.bytesInTotal > 0 {
            title = " \(Int(100 * Double(b.bytesInDone) / Double(b.bytesInTotal)))%"
        } else if s.pendingApprovals > 0 {
            title = " \(s.pendingApprovals)"
        }
        item.button?.title = title
        item.button?.toolTip = "Convertable — \(Self.label(s.state))"
    }

    static func label(_ s: AppState) -> String {
        switch s {
        case .idle: return "Idle"; case .scanning: return "Scanning"; case .converting: return "Converting"; case .paused: return "Paused"
        case .batchComplete: return "Batch complete"; case .attention: return "Needs attention"; case .volumeUnavailable: return "Volume unavailable"
        }
    }

    // MARK: Menu (rebuilt each time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let s = snapshot else { menu.addItem(disabled("Starting…")); return }

        menu.addItem(disabled(Self.label(s.state)))
        menu.addItem(disabled(s.volumeAvailable ? "● \(s.volume)" : "○ \(s.volume)"))
        menu.addItem(disabled(s.musicLibraryOpen ? "● Music: iPod library open" : (s.musicRunning ? "○ Music: other library open" : "○ Music not running")
                              + (s.musicPending > 0 ? " · \(s.musicPending) waiting" : "")))
        if let b = s.batch ?? batch, s.state == .converting || s.state == .paused {
            menu.addItem(.separator())
            menu.addItem(disabled("Batch #\(b.id): \(b.albumsDone)/\(b.albumsTotal) albums · \(b.tracksDone)/\(b.tracksTotal) tracks"))
            menu.addItem(disabled("\(ByteCount.string(b.bytesInDone)) of \(ByteCount.string(b.bytesInTotal)) → \(ByteCount.string(b.bytesOut))"))
            if let cur = b.currentAlbum { menu.addItem(disabled("▶ \(cur)")) }
        } else {
            let L = s.library
            menu.addItem(disabled("Backlog: \(L.backlogAlbums) albums · \(ByteCount.string(L.backlogBytes))" + (L.settlingAlbums > 0 ? " · \(L.settlingAlbums) settling" : "")))
        }
        for a in s.alerts.prefix(3) { menu.addItem(disabled("⚠︎ \(a.message.prefix(90))")) }
        if let e = serverError { menu.addItem(disabled("⚠︎ Dashboard server: \(e.prefix(80))")) }

        menu.addItem(.separator())
        if s.state == .converting {
            menu.addItem(action("Pause after current tracks", #selector(pause)))
        } else {
            let start = action("Start next batch", #selector(startNext))
            start.isEnabled = s.volumeAvailable && s.library.backlogAlbums > 0
            menu.addItem(start)
        }
        let scan = action("Scan now", #selector(scanNow)); scan.isEnabled = s.volumeAvailable && s.scanInProgress == nil; menu.addItem(scan)
        let imp = action("Import into Music now", #selector(importNow)); imp.isEnabled = s.musicPending > 0; menu.addItem(imp)
        menu.addItem(.separator())
        menu.addItem(action("Open Dashboard", #selector(openDashboard), key: "d"))
        let lal = action("Launch at Login", #selector(toggleLaunchAtLogin))
        lal.state = LaunchAtLogin.isEnabled ? .on : .off
        lal.isEnabled = LaunchAtLogin.isAvailable
        menu.addItem(lal)
        menu.addItem(.separator())
        menu.addItem(action("Quit Convertable", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem { let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.target = self; return i
    }

    // MARK: Actions

    @objc private func pause() { Task { try? await controller.perform(.stop) } }
    @objc private func startNext() {
        Task {
            let cap = await controller.settings.batchBudgetBytes
            try? await controller.perform(.startBatch(Selection(mode: .size, cap: cap), exceedCap: false))
        }
    }
    @objc private func scanNow() { Task { try? await controller.perform(.scan(full: false)) } }
    @objc private func importNow() { Task { try? await controller.perform(.importNow) } }
    @objc private func openDashboard() { if let u = URL(string: dashboardURL) { NSWorkspace.shared.open(u) } }
    @objc private func toggleLaunchAtLogin() {
        do { try LaunchAtLogin.set(!LaunchAtLogin.isEnabled) } catch { notifier.post(title: "Launch at Login", body: "\(error)") }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
