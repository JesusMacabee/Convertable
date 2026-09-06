import AppKit
import ConvertableCore
import ConvertableWeb

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController!
    private var server: WebServer!
    private var statusItem: StatusItemController!
    private var serverTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private let notifier = Notifier()
    private var lastSnapshot: StatusSnapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let settings = try Settings.load()
            if !FileManager.default.fileExists(atPath: Settings.defaultURL.path) { try settings.save() }
            let store = try Store(path: Settings.defaultDatabaseURL.path)
            controller = AppController(settings: settings, store: store)
            server = WebServer(controller: controller, settings: settings)
        } catch {
            let alert = NSAlert(); alert.messageText = "Convertable could not start"; alert.informativeText = "\(error)"; alert.runModal()
            NSApp.terminate(nil); return
        }

        statusItem = StatusItemController(controller: controller, dashboardURL: server.localURL, notifier: notifier)
        notifier.requestPermissionIfBundled()
        if !(try? Settings.load())!.setupCompleted {
            // First run: bring the person straight to the setup flow once the server is listening.
            let url = server.localURL
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
        }

        // The dashboard server must outlive any single failure (port briefly busy, network stack hiccup): restart with backoff.
        serverTask = Task { [server] in
            var delay: UInt64 = 2
            while !Task.isCancelled {
                do {
                    NSLog("Convertable: dashboard server starting on port %d", server!.port)
                    try await server!.runEmbedded()
                    NSLog("Convertable: dashboard server stopped")
                } catch {
                    NSLog("Convertable: dashboard server failed: %@", "\(error)")
                    await MainActor.run { self.statusItem.serverError = "\(error) — retrying" }
                }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 60)
            }
        }
        Task { await controller.startScheduler() }

        eventTask = Task { [weak self] in
            guard let self else { return }
            let (_, stream) = await controller.bus.subscribe()
            await self.apply(await controller.status())
            for await ev in stream {
                switch ev {
                case let .status(s): await self.apply(s)
                case let .batchProgress(b): await MainActor.run { self.statusItem.batch = b }
                default: break
                }
            }
        }
    }

    @MainActor private func apply(_ s: StatusSnapshot) {
        statusItem.snapshot = s
        notifier.transition(from: lastSnapshot, to: s)
        lastSnapshot = s
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await controller?.shutdown() }
    }
}
