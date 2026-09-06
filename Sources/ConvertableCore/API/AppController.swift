import Foundation

/// The one object that owns the app's behaviour. The dashboard, the menu bar and the CLI are all
/// clients of this API. Scheduling (periodic scans, auto-continue) lives here too.
public actor AppController {
    public private(set) var settings: Settings
    public nonisolated let store: Store
    public nonisolated let bus: EventBus
    public let startedAt = Date()

    private var shareIO: ShareIO
    private var state: AppState = .idle
    private var scanTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var schedulerTask: Task<Void, Never>?
    private var scanProgressText: String?
    private var batch: BatchProgress?
    private var stopRequested = false
    private var lastBatchEndedBy: String?
    private var nextScanAt: Date?
    private var alerts: [Alert] = []
    private var lastVolumeStatus: VolumeStatus?
    private var learnedRatio: Double?   // real out/in for lossless transcodes, once known
    private var musicTask: Task<Void, Never>?
    private var musicImportDisabled: String?
    private var musicPendingCache = 0
    private var reconciledThisLaunch = false
    public var musicBridge = MusicBridge()

    public init(settings: Settings, store: Store, bus: EventBus = EventBus()) {
        self.settings = settings
        self.store = store
        self.bus = bus
        let mount = VolumeGate.mountInfo(containing: settings.sourceRoot)
        self.shareIO = ShareIO(limit: settings.shareConcurrencyOverride ?? mount?.suggestedConcurrency ?? 1, maxLimit: 8)
    }

    // MARK: Lifecycle

    private var scansEnabled = true

    /// Starts the background loop: volume monitoring every 30 s, plus periodic scans and
    /// auto-continue unless `scans` is false. Safe to call once.
    public func startScheduler(scans: Bool = true) {
        guard schedulerTask == nil else { return }
        scansEnabled = scans
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.schedulerTick()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    public func shutdown() {
        schedulerTask?.cancel(); scanTask?.cancel()
        stopRequested = true
    }

    private func schedulerTick() async {
        // Volume gate first; everything else waits on it.
        // The probe can block on a stalled mount; keep it off the actor's executor.
        let root = settings.sourceRoot
        let t0 = Date()
        var vs = await Task.detached(priority: .utility) { VolumeGate.check(root: root, timeout: 15) }.value
        if case .unresponsive = vs {
            // One slow listing is not an outage (seen once at process start). Confirm before alarming.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let again = await Task.detached(priority: .utility) { VolumeGate.check(root: root, timeout: 15) }.value
            try? store.log("debug", "volume", String(format: "probe slow (%.1f s); recheck → %@", Date().timeIntervalSince(t0), "\(again)"))
            vs = again
        }
        let changed = lastVolumeStatus != vs
        volumeChanged(vs)
        if changed { await publishStatus() }
        guard case .available = vs, scansEnabled else { return }
        let now = Date()
        if scanTask == nil, batchTask == nil {
            let lastFull = (try? store.lastFinishedScan(.full))?.finishedAt
            let lastAny = (try? store.lastFinishedScan())?.finishedAt
            let dueIncremental = lastAny.map { now.timeIntervalSince1970 - $0 >= Double(settings.incrementalScanMinutes * 60) } ?? true
            let fullDue = lastFull.map { now.timeIntervalSince1970 - $0 >= 20 * 3600 && Calendar.current.component(.hour, from: now) == settings.fullScanHour } ?? true
            if fullDue { scan(full: true) } else if dueIncremental { scan(full: false) }
            nextScanAt = now.addingTimeInterval(Double(settings.incrementalScanMinutes * 60))
        }
        if batchTask == nil, scanTask == nil, autoContinueAllowed(now) {
            // Steady state: process whatever is eligible under the configured budget.
            startBatch(Selection(mode: .size, cap: settings.batchBudgetBytes), exceedCap: false)
        }
        importIntoMusic()
    }

    // MARK: Music import

    private func makeImporter() -> MusicImporter? {
        guard let profile = Profile.named(settings.profileID) else { return nil }
        return MusicImporter(store: store, settings: settings, profile: profile, bridge: musicBridge)
    }

    /// Drains complete albums into Music when the configured library is open. Never runs two at once.
    public func importIntoMusic(force: Bool = false) {
        guard musicTask == nil, let importer = makeImporter() else { return }
        if let reason = musicImportDisabled, !force {
            _ = reason; return
        }
        if force { musicImportDisabled = nil; alerts.removeAll { $0.id == "music-disabled" } }
        musicTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var outcome = MusicImporter.Outcome()
            let ready = importer.libraryReady()
            if case .success = ready {
                if !(await self.reconciledThisLaunch) {
                    if let r = try? importer.reconcile() {
                        try? self.store.log("info", "music", "reconciled with Music: \(r.matched) matched, \(r.unknownInMirror) unknown files under the mirror")
                    }
                    await self.setReconciled()
                }
                outcome = importer.drain()
            }
            await self.musicDrainFinished(outcome, ready: ready)
        }
    }

    private func setReconciled() { reconciledThisLaunch = true }

    private func musicDrainFinished(_ o: MusicImporter.Outcome, ready: Result<Void, MusicError>) async {
        musicTask = nil
        musicPendingCache = makeImporter()?.pendingCount() ?? 0
        if let reason = o.disabledReason {
            musicImportDisabled = reason
            raise(Alert(id: "music-disabled", level: "error", message: reason, action: "enableMusicImport"))
        }
        if case let .failure(e) = ready, musicPendingCache > 0 {
            raise(Alert(id: "music-gate", level: "info", message: "\(musicPendingCache) track(s) ready for Music — waiting: \(e.description)", action: nil))
        } else {
            alerts.removeAll { $0.id == "music-gate" }
        }
        if o.added > 0 || o.failed > 0 { await publishStatus() }
    }

    private func autoContinueAllowed(_ now: Date) -> Bool {
        switch settings.autoContinue {
        case .off: return false
        case .on: return true
        case let .window(start, end):
            let h = Calendar.current.component(.hour, from: now)
            return start <= end ? (h >= start && h < end) : (h >= start || h < end)
        }
    }

    // MARK: Commands

    public func perform(_ command: Command) async throws {
        switch command {
        case let .scan(full): scan(full: full)
        case let .startBatch(sel, exceed): startBatch(sel, exceedCap: exceed)
        case .stop: requestStop(); if batch != nil { state = .paused }
        case let .pin(dir, pinned): try store.pin(dir, pinned: pinned)
        case .importNow: importIntoMusic()
        case .enableMusicImport: importIntoMusic(force: true)
        }
        await publishStatus()
    }

    public func updateSettings(_ new: Settings) throws {
        try new.save()
        settings = new
        let mount = VolumeGate.mountInfo(containing: new.sourceRoot)
        shareIO = ShareIO(limit: new.shareConcurrencyOverride ?? mount?.suggestedConcurrency ?? 1, maxLimit: 8)
    }

    public func scan(full: Bool) {
        guard scanTask == nil else { return }
        let scanner = LibraryScanner(root: settings.sourceRoot, store: store)
        state = .scanning
        scanProgressText = full ? "full scan starting" : "incremental scan"
        scanTask = Task { [weak self] in
            guard let self else { return }
            scanner.onProgress = { p in
                Task { await self.scanProgress(p) }
            }
            do {
                let p = full ? try scanner.fullScan() : try scanner.incrementalScan()
                try? self.store.log("info", "scan", "\(full ? "full" : "incremental") scan: \(p.files) files, +\(p.added) ~\(p.changed) −\(p.missing)")
            } catch {
                try? self.store.log("error", "scan", "\(error)")
                await self.raise(Alert(id: "scan", level: "error", message: "Scan failed: \(error)", action: nil))
            }
            await self.scanFinished()
        }
    }

    private func scanProgress(_ p: LibraryScanner.Progress) async {
        scanProgressText = "\(p.files) files · \(p.currentArtist)"
        await bus.publish(.scanProgress(dirs: p.dirs, files: p.files, artist: p.currentArtist))
    }

    private func scanFinished() async {
        scanTask = nil; scanProgressText = nil
        if batch == nil { state = lastBatchEndedBy == "budget" ? .batchComplete : .idle }
        await publishStatus()
    }

    public func startBatch(_ selection: Selection, exceedCap: Bool) {
        guard batchTask == nil else { return }
        stopRequested = false
        var sel = selection
        if exceedCap { sel.cap = nil }
        guard let profile = Profile.named(settings.profileID) else { return }
        let planner = Planner(store: store, profile: profile, fileSettleSeconds: settings.fileSettleSeconds, albumSettleSeconds: settings.albumSettleSeconds)
        guard let plan = try? planner.plan(sel), !plan.albums.isEmpty else { return }
        guard case .available = VolumeGate.check(root: settings.sourceRoot, timeout: 15) else { return }

        let selJSON = (try? JSONEncoder().encode(sel)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        guard let batchID = try? store.db.insert("INSERT INTO batches (selection_json, budget_bytes, started_at) VALUES (?,?,?)",
                                                 [.text(selJSON), Database.Value(sel.cap), .real(Date().timeIntervalSince1970)]) else { return }
        var progress = BatchProgress(id: batchID, selection: sel.description, albumsTotal: plan.albums.count, albumsDone: 0,
                                     tracksTotal: plan.trackCount, tracksDone: 0, tracksFailed: 0, bytesInTotal: plan.bytesIn, bytesInDone: 0, bytesOut: 0,
                                     startedAt: Date().timeIntervalSince1970, currentAlbum: nil, currentTracks: [],
                                     backlogAlbums: plan.backlogAlbums, backlogBytes: plan.backlogBytes)
        batch = progress
        state = .converting
        let work = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Convertable/work").path
        let config = Pipeline.Config(sourceRoot: settings.sourceRoot, mirrorRoot: settings.mirrorRoot, workDir: work,
                                     encodeConcurrency: settings.encodeConcurrency, artMaxPixels: settings.artMaxPixels,
                                     artJPEGQuality: settings.artJPEGQuality, profileID: profile.id)
        try? FileManager.default.createDirectory(atPath: settings.mirrorRoot, withIntermediateDirectories: true)
        let pipeline = Pipeline(config: config, store: store, shareIO: shareIO)
        pipeline.shouldStop = { [weak self] in
            guard let self else { return true }
            // Synchronous check from a non-isolated context: read a copy kept outside the actor.
            return self.stopFlag.value
        }
        stopFlag.value = false
        pipeline.onEvent = { [weak self] ev in Task { await self?.pipelineEvent(ev) } }
        batchTask = Task { [weak self] in
            let summary = await pipeline.run(plan, batchID: batchID)
            await self?.batchFinished(summary, progress: &progress)
        }
        Task { await publishStatus() }
    }

    private let stopFlag = AtomicFlag()

    private func pipelineEvent(_ ev: Pipeline.Event) async {
        guard var b = batch else { return }
        switch ev {
        case let .albumStarted(a):
            b.currentAlbum = "\(a.displayArtist) — \(a.displayAlbum)"; b.currentTracks = a.tracks.map(\.source.fileName)
        case let .trackFinished(r):
            b.tracksDone += r.ok ? 1 : 0; b.tracksFailed += r.ok ? 0 : 1
            b.bytesInDone += r.track.source.size; b.bytesOut += r.outputBytes
            b.currentTracks.removeAll { $0 == r.track.source.fileName }
            if r.ok, case .transcode = r.track.action, r.track.source.kind == .lossless, r.track.source.size > 0 {
                let ratio = Double(r.outputBytes) / Double(r.track.source.size)
                learnedRatio = learnedRatio.map { $0 * 0.9 + ratio * 0.1 } ?? ratio
            }
            let row = ActivityRow(id: 0, at: Date().timeIntervalSince1970, level: r.ok ? "info" : "error", category: "pipeline",
                                  message: r.ok ? "\(r.track.action.label) → \((r.track.outputRelPath as NSString).lastPathComponent)" : "failed: \(r.error ?? "?")",
                                  relPath: r.track.source.relPath)
            await bus.publish(.activity(row))
        case .albumFinished:
            b.albumsDone += 1; b.currentAlbum = nil
            importIntoMusic()   // a finished album can go straight to Music
        case .message: break
        }
        batch = b
        await bus.publish(.batchProgress(b))
    }

    private func batchFinished(_ summary: Pipeline.Summary, progress: inout BatchProgress) async {
        batchTask = nil
        lastBatchEndedBy = summary.endedBy
        let msg = "Batch #\(progress.id) \(summary.endedBy): \(summary.tracksDone) ok, \(summary.tracksFailed) failed, \(ByteCount.string(summary.bytesIn)) → \(ByteCount.string(summary.bytesOut))"
        try? store.log(summary.tracksFailed > 0 ? "warn" : "info", "batch", msg)
        batch = nil
        if summary.tracksFailed > 0 { raise(Alert(id: "batch-\(progress.id)", level: "warn", message: "\(summary.tracksFailed) track(s) failed in batch #\(progress.id) — see Activity", action: nil)) }
        state = summary.endedBy == "user" ? .paused : (summary.endedBy == "budget" ? .batchComplete : .idle)
        await publishStatus()
    }

    // MARK: Queries

    public func status() -> StatusSnapshot {
        let vs = lastVolumeStatus ?? quickVolumeCheck()
        var available = false; var proto: String?; var volText = settings.sourceRoot
        switch vs {
        case let .available(m): available = true; proto = m.fsType; volText = "\(m.mountPoint) (\(m.fsType))"
        case let .notMounted(v): volText = "\(v) not mounted"
        case let .pathMissing(p): volText = "missing: \(p)"
        case let .unresponsive(p): volText = "unresponsive: \(p)"
        }
        let c = (try? store.counts()) ?? Store.Counts(active: 0, missing: 0, lossless: 0, lossy: 0, bytes: 0, mirrored: 0, artists: 0, albums: 0, directories: 0)
        let backlog = backlogSummary()
        let effective: AppState = !available ? .volumeUnavailable : (alerts.contains { $0.level == "error" } ? .attention : state)
        return StatusSnapshot(state: effective, volume: volText, volumeAvailable: available, protocolName: proto,
                              musicLibraryOpen: MusicPrefs.isConfiguredLibraryOpen(settings), musicRunning: MusicPrefs.isRunning,
                              batch: batch,
                              library: LibraryCounts(artists: c.artists, albums: c.albums, tracks: c.active, lossless: c.lossless, lossy: c.lossy, bytes: c.bytes,
                                                     mirrored: c.mirrored, missing: c.missing, backlogAlbums: backlog.albums, backlogBytes: backlog.bytes, settlingAlbums: backlog.settling),
                              lastFullScan: (try? store.lastFinishedScan(.full))?.finishedAt,
                              lastIncrementalScan: (try? store.lastFinishedScan(.incremental))?.finishedAt,
                              nextScan: nextScanAt?.timeIntervalSince1970, scanInProgress: scanProgressText,
                              pendingApprovals: 0, musicPending: musicPendingCache, musicImportDisabled: musicImportDisabled,
                              alerts: alerts, shareLimit: 0, shareInFlight: 0,
                              uptimeSeconds: Date().timeIntervalSince(startedAt))
    }

    /// Mount-table + existence only; no directory listing, so it cannot hang.
    private func quickVolumeCheck() -> VolumeStatus {
        let root = settings.sourceRoot
        if let vol = VolumeGate.expectedVolume(for: root) {
            guard let info = VolumeGate.mountInfo(containing: root), info.mountPoint == vol else { return .notMounted(expectedMountPoint: vol) }
            return FileManager.default.fileExists(atPath: root) ? .available(info) : .pathMissing(root)
        }
        return FileManager.default.fileExists(atPath: root) ? .available(VolumeGate.mountInfo(containing: root) ?? MountInfo(mountPoint: "/", fsType: "local", mountedFrom: "")) : .pathMissing(root)
    }

    private func backlogSummary() -> (albums: Int, bytes: Int64, settling: Int) {
        guard let profile = Profile.named(settings.profileID) else { return (0, 0, 0) }
        let planner = Planner(store: store, profile: profile, fileSettleSeconds: settings.fileSettleSeconds, albumSettleSeconds: settings.albumSettleSeconds)
        guard let plan = try? planner.plan(Selection(mode: .everything)) else { return (0, 0, 0) }
        let settling = plan.ineligible.filter { if case .settling = $0.1 { return true }; return false }.count
        return (plan.albums.count, plan.bytesIn, settling)
    }

    public func artists() -> [ArtistRow] {
        ((try? store.artistSummaries()) ?? []).map {
            ArtistRow(dir: $0.artistDir, name: $0.displayName, albums: $0.albums, tracks: $0.tracks, bytes: $0.bytes, mirrored: $0.mirrored, pinned: $0.pinned, status: $0.status)
        }
    }

    public func albums(artist: String) -> [AlbumRow] {
        ((try? store.albumSummaries(artist: artist)) ?? []).map {
            AlbumRow(artistDir: $0.key.artistDir, albumDir: $0.key.albumDir, name: $0.displayAlbum ?? ($0.key.albumDir.isEmpty ? "(loose files)" : $0.key.albumDir),
                     tracks: $0.tracks, bytes: $0.bytes, mirrored: $0.mirrored, lossless: $0.losslessTracks, lossy: $0.lossyTracks,
                     status: $0.mirrored == 0 ? "none" : ($0.mirrored == $0.tracks ? "complete" : "partial"), firstSeen: $0.firstSeen)
        }
    }

    public func preview(_ selection: Selection) throws -> PlanPreview {
        guard let profile = Profile.named(settings.profileID) else { throw CocoaError(.featureUnsupported) }
        let planner = Planner(store: store, profile: profile, fileSettleSeconds: settings.fileSettleSeconds, albumSettleSeconds: settings.albumSettleSeconds)
        let plan = try planner.plan(selection)
        func row(_ a: PlannedAlbum) -> PlanPreview.Album {
            var est = a.estimatedOutBytes
            if let r = learnedRatio {
                est = a.tracks.reduce(0) { acc, t in
                    if case .transcode = t.action, t.source.kind == .lossless { return acc + Int64(Double(t.source.size) * r) }
                    return acc + t.estimatedOutBytes
                }
            }
            return .init(artistDir: a.key.artistDir, albumDir: a.key.albumDir, artist: a.displayArtist, album: a.displayAlbum, tracks: a.tracks.count, bytesIn: a.bytesIn, estimatedOut: est, pinned: a.pinned)
        }
        let albums = plan.albums.map(row), overflow = plan.overflow.map(row)
        // ~2 s of encode per track at the measured local rate, divided by parallelism, plus share copy time.
        let seconds = Double(plan.trackCount) * 2.5 / Double(max(1, settings.encodeConcurrency)) + Double(plan.bytesIn) / 60_000_000
        return PlanPreview(selection: selection, albums: albums, overflow: overflow, bytesIn: plan.bytesIn,
                           estimatedOut: albums.reduce(0) { $0 + $1.estimatedOut }, tracks: plan.trackCount,
                           overflowBytes: plan.overflowBytes, backlogAlbums: plan.backlogAlbums, backlogBytes: plan.backlogBytes,
                           settling: plan.ineligible.filter { if case .settling = $0.1 { return true }; return false }.count,
                           alreadyMirrored: plan.ineligible.filter { $0.1 == .nothingToDo }.count,
                           skipped: plan.ineligible.filter { $0.1 == .allSkipped }.count, estimatedSeconds: seconds)
    }

    public func batches(limit: Int = 50) -> [BatchRow] {
        (try? store.db.query("SELECT * FROM batches ORDER BY id DESC LIMIT ?", [.integer(Int64(limit))]) { r in
            BatchRow(id: r.int("id")!, selection: Self.describe(selectionJSON: r.text("selection_json") ?? ""), budgetBytes: r.int("budget_bytes"),
                     bytesIn: r.int("bytes_in") ?? 0, bytesOut: r.int("bytes_out") ?? 0, filesDone: Int(r.int("files_done") ?? 0),
                     startedAt: r.double("started_at")!, finishedAt: r.double("finished_at"), endedBy: r.text("ended_by"))
        }) ?? []
    }

    static func describe(selectionJSON: String) -> String {
        (try? JSONDecoder().decode(Selection.self, from: Data(selectionJSON.utf8)))?.description ?? "batch"
    }

    public func activity(limit: Int = 200, level: String? = nil, search: String? = nil) -> [ActivityRow] {
        var sql = "SELECT id, at, level, category, message, rel_path FROM activity WHERE 1=1"
        var params: [Database.Value] = []
        if let level, level != "all" { sql += " AND level=?"; params.append(.text(level)) }
        if let search, !search.isEmpty { sql += " AND (message LIKE ? OR rel_path LIKE ?)"; params += [.text("%\(search)%"), .text("%\(search)%")] }
        sql += " ORDER BY id DESC LIMIT ?"; params.append(.integer(Int64(limit)))
        return (try? store.db.query(sql, params) { r in
            ActivityRow(id: r.int(0)!, at: r.double(1)!, level: r.text(2)!, category: r.text(3)!, message: r.text(4)!, relPath: r.text(5))
        }) ?? []
    }

    // MARK: Alerts / status publishing

    private func raise(_ a: Alert) {
        alerts.removeAll { $0.id == a.id }; alerts.append(a)
    }
    public func dismissAlert(_ id: String) async { alerts.removeAll { $0.id == id }; await publishStatus() }

    private func volumeChanged(_ vs: VolumeStatus) {
        let was = lastVolumeStatus
        lastVolumeStatus = vs
        if case .available = vs {
            alerts.removeAll { $0.id == "volume" }
            if let was, case .available = was {} else if was != nil { try? store.log("info", "volume", "share available again") }
        } else if alerts.first(where: { $0.id == "volume" }) == nil {
            raise(Alert(id: "volume", level: "error", message: "Source volume unavailable: \(vs). Nothing will run until it is mounted.", action: nil))
            try? store.log("warn", "volume", "\(vs)")
        }
    }

    public func publishStatus() async {
        var s = status()
        s.shareLimit = await shareIO.limit
        await bus.publish(.status(s))
    }

    public func requestStop() { stopFlag.value = true; stopRequested = true }
}

/// A tiny thread-safe flag readable from non-isolated closures (the pipeline's `shouldStop`).
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
