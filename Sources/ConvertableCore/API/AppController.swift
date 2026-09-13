import Foundation

/// A command the controller declined to carry out, with a user-facing reason.
public enum ControllerError: Error, LocalizedError, Equatable {
    case refused(String)
    public var errorDescription: String? { if case let .refused(why) = self { return why }; return nil }
}

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
            if fullDue { scan(full: true); await dailyMaintenance() } else if dueIncremental { scan(full: false) }
            nextScanAt = now.addingTimeInterval(Double(settings.incrementalScanMinutes * 60))
        }
        if batchTask == nil, scanTask == nil, autoContinueAllowed(now) {
            // Steady state: process whatever is eligible under the configured budget.
            startBatch(Selection(mode: .size, cap: settings.batchBudgetBytes), exceedCap: false)
        }
        importIntoMusic()
    }

    // MARK: Review

    public func proposals() -> [Store.Proposal] { (try? store.proposals(states: ["pending", "approved"])) ?? [] }

    /// Approves every pending proposal of one kind. Returns how many were approved.
    public func approveAll(kind: String) async throws -> Int {
        var n = 0
        for p in try store.proposals(states: ["pending"]) where p.kind == kind { try await approve(p.id); n += 1 }
        return n
    }

    public func approve(_ id: Int64) async throws {
        guard let p = try store.proposal(id: id), p.state == "pending" else { return }
        try store.setProposalState(id, "approved")
        let reviewer = Reviewer(store: store, mirrorRoot: settings.mirrorRoot)
        switch p.kind {
        case "remove":
            let remaining = try await reviewer.applyRemove(p, shareIO: shareIO)
            if remaining.isEmpty { try store.setProposalState(id, "done") }
            else {
                let json = String(decoding: try JSONEncoder().encode(remaining), as: UTF8.self)
                try store.db.run("UPDATE proposals SET items_json=? WHERE id=?", [.text(json), .integer(id)])
                importIntoMusic()   // Music-side removals when the library is open
            }
        default:
            importIntoMusic()   // supersede is applied with the library open (MusicImporter.processPending)
        }
    }

    private func dailyMaintenance() async {
        let reviewer = Reviewer(store: store, mirrorRoot: settings.mirrorRoot)
        _ = await reviewer.purgeQuarantine(retentionDays: settings.quarantineRetentionDays, shareIO: shareIO)
        indexLegacy()
    }

    private var legacyTask: Task<Void, Never>?
    private var deadScanTask: Task<Void, Never>?
    public private(set) var deadScanRunning = false

    /// Walks Music for entries whose files are gone (minutes on a big library) and proposes their removal.
    public func scanDeadEntries() {
        guard deadScanTask == nil, MusicPrefs.isRunning, MusicPrefs.isConfiguredLibraryOpen(settings) else {
            raise(Alert(id: "dead-scan", level: "info", message: "Dead-entry scan needs the configured Music library to be open.", action: nil)); return
        }
        deadScanRunning = true
        let bridge = musicBridge
        let reviewer = Reviewer(store: store, mirrorRoot: settings.mirrorRoot)
        deadScanTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let dead = try bridge.deadTracks()
                let n = try reviewer.proposeDeadEntries(dead)
                try? self.store.log("info", "review", "dead-entry scan: \(dead.count) Music entries without files, \(n) new proposal(s)")
            } catch { try? self.store.log("error", "review", "dead-entry scan failed: \(error)") }
            await self.deadScanFinished()
        }
    }
    private func deadScanFinished() async { deadScanTask = nil; deadScanRunning = false; alerts.removeAll { $0.id == "dead-scan" }; await publishStatus() }

    /// Indexes the legacy library (incremental) and proposes supersedes. Runs in the background.
    public func indexLegacy() {
        guard settings.supersedeEnabled, legacyTask == nil, let profile = Profile.named(settings.profileID) else { return }
        let indexer = LegacyIndexer(store: store, roots: settings.legacyMediaRoots)
        let matcher = SupersedeMatcher(store: store, profile: profile)
        let io = shareIO
        let bridge = musicBridge
        let roots = settings.legacyMediaRoots
        let libraryOpen = MusicPrefs.isConfiguredLibraryOpen(settings) && MusicPrefs.isRunning
        legacyTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            if let r = try? await indexer.run(shareIO: io) {
                try? self.store.log("info", "legacy", "legacy index: \(r.seen) files seen, \(r.indexed) (re)indexed, \(r.removed) gone")
            }
            if libraryOpen, let n = try? SupersedeMatcher.mapMusicIDs(store: self.store, roots: roots, bridge: bridge) {
                try? self.store.log("info", "legacy", "mapped \(n) legacy tracks to Music")
            }
            if let n = try? matcher.run(), n > 0 {
                try? self.store.log("info", "review", "\(n) proposal(s) to replace old AAC copies await your approval")
            }
            await self.legacyFinished()
        }
    }
    private func legacyFinished() async { legacyTask = nil; await publishStatus() }

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
                // Reconciling walks the whole library (~8 min for 13k tracks): only when an output has lost its Music ID.
                let lostIDs = (try? self.store.db.scalar("SELECT COUNT(*) FROM outputs WHERE music_added_at IS NOT NULL AND music_persistent_id IS NULL")) == .integer(0) ? false : true
                if !(await self.reconciledThisLaunch), lostIDs {
                    if let r = try? importer.reconcile() {
                        try? self.store.log("info", "music", "reconciled with Music: \(r.matched) matched, \(r.unknownInMirror) unknown files under the mirror")
                    }
                    await self.setReconciled()
                }
                outcome = importer.drain()
                let mirror = await self.settings.mirrorRoot
                let p = importer.processPending(mirrorRoot: mirror, reviewer: Reviewer(store: self.store, mirrorRoot: mirror))
                if p.refreshed + p.relocated + p.removed > 0 {
                    try? self.store.log("info", "music", "refreshed \(p.refreshed), relocated \(p.relocated), removed \(p.removed)")
                }
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
        case let .startBatch(sel, exceed): if let why = startBatch(sel, exceedCap: exceed) { throw ControllerError.refused(why) }
        case .stop: requestStop(); if batch != nil { state = .paused }
        case let .pin(dir, pinned): try store.pin(dir, pinned: pinned)
        case let .ignoreAlbum(artist, album, ignored): try store.ignore(AlbumKey(artistDir: artist, albumDir: album), ignored: ignored); backlogCache = nil; await publishStatus()
        case .importNow: importIntoMusic()
        case .enableMusicImport: importIntoMusic(force: true)
        case let .approve(id): try await approve(id)
        case let .dismiss(id): try store.setProposalState(id, "dismissed")
        case .indexLegacy: indexLegacy()
        case .scanDeadEntries: scanDeadEntries()
        case .auditTags: auditTags()
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
                // Routine scans are noise at info level; anything that actually changed is still surfaced.
                let changed = p.added + p.changed + p.missing + p.reappeared
                try? self.store.log(changed > 0 ? "info" : "debug", "scan", "\(full ? "full" : "incremental") scan: \(p.files) files, +\(p.added) ~\(p.changed) −\(p.missing)")
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

    private var auditTask: Task<Void, Never>?

    /// Reads tags of new/changed files (MusicBrainz presence, names, path fields), then re-paths mirrored
    /// albums whose tags now allow a tag-derived name. Background; share I/O through ShareIO.
    public func auditTags() {
        guard auditTask == nil else { return }
        let audit = TagAudit(store: store, sourceRoot: settings.sourceRoot)
        let io = shareIO, mirror = settings.mirrorRoot, derived = settings.tagDerivedPaths, profileID = settings.profileID
        auditTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            if let r = try? await audit.run(shareIO: io), r.audited + r.failed > 0 {
                try? self.store.log("info", "tags", "tag audit: \(r.audited) files read, \(r.withMBID) with MusicBrainz IDs, \(r.failed) unreadable")
            }
            if derived, let profile = Profile.named(profileID) {
                let moved = await Reviewer(store: self.store, mirrorRoot: mirror).repathMirror(profile: profile, shareIO: io)
                if moved > 0 { try? self.store.log("info", "tags", "renamed \(moved) mirror files to tag-derived paths") }
            }
            await self.auditFinished()
        }
    }
    private func auditFinished() async { auditTask = nil; backlogCache = nil; await publishStatus(); importIntoMusic() }

    private func scanFinished() async {
        scanTask = nil; scanProgressText = nil
        auditTags()
        // Review pass after every scan: withdraw proposals whose sources came back, propose new orphans.
        let reviewer = Reviewer(store: store, mirrorRoot: settings.mirrorRoot)
        _ = try? reviewer.withdrawStaleProposals()
        if let n = try? reviewer.detectOrphans(), n > 0 {
            try? store.log("info", "review", "\(n) new removal proposal(s) awaiting your approval")
            await bus.publish(.activity(ActivityRow(id: 0, at: Date().timeIntervalSince1970, level: "warn", category: "review", message: "\(n) new removal proposal(s) await approval", relPath: nil)))
        }
        importIntoMusic()
        if batch == nil { state = lastBatchEndedBy == "budget" ? .batchComplete : .idle }
        await publishStatus()
    }

    /// Starts a batch; returns the reason when nothing was started so callers (API, dashboard) can say so
    /// instead of silently reporting the batch that was already running.
    @discardableResult
    public func startBatch(_ selection: Selection, exceedCap: Bool) -> String? {
        guard batchTask == nil else { return "a batch is already running — stop it or wait for it to finish" }
        stopRequested = false
        var sel = selection
        if exceedCap { sel.cap = nil }
        guard let profile = Profile.named(settings.profileID) else { return "unknown output profile \(settings.profileID)" }
        let planner = makePlanner(profile)
        guard let plan = try? planner.plan(sel), !plan.albums.isEmpty else { return "nothing eligible in that selection" }
        guard case .available = VolumeGate.check(root: settings.sourceRoot, timeout: 15) else { return "source volume is not available" }

        let selJSON = (try? JSONEncoder().encode(sel)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        guard let batchID = try? store.db.insert("INSERT INTO batches (selection_json, budget_bytes, started_at) VALUES (?,?,?)",
                                                 [.text(selJSON), Database.Value(sel.cap), .real(Date().timeIntervalSince1970)]) else { return "could not record the batch in the state database" }
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
        return nil
    }

    private let stopFlag = AtomicFlag()

    private func pipelineEvent(_ ev: Pipeline.Event) async {
        guard var b = batch else { return }
        var activity: ActivityRow?
        // Read-modify-write with no suspension in between: events arrive concurrently.
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
            activity = ActivityRow(id: 0, at: Date().timeIntervalSince1970, level: r.ok ? "info" : "error", category: "pipeline",
                                   message: r.ok ? "\(r.track.action.label) → \((r.track.outputRelPath as NSString).lastPathComponent)" : "failed: \(r.error ?? "?")",
                                   relPath: r.track.source.relPath)
        case .albumFinished:
            b.albumsDone += 1; b.currentAlbum = nil
            importIntoMusic()   // a finished album can go straight to Music
        case .message: break
        }
        batch = b
        if let activity { await bus.publish(.activity(activity)) }
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
                                                     mirrored: c.mirrored, missing: c.missing, backlogAlbums: backlog.albums, backlogBytes: backlog.bytes, settlingAlbums: backlog.settling,
                                                     needsTaggingAlbums: backlog.needsTagging, needsTaggingTracks: backlog.needsTaggingTracks, auditingAlbums: backlog.auditing),
                              lastFullScan: (try? store.lastFinishedScan(.full))?.finishedAt,
                              lastIncrementalScan: (try? store.lastFinishedScan(.incremental))?.finishedAt,
                              nextScan: nextScanAt?.timeIntervalSince1970, scanInProgress: scanProgressText,
                              pendingApprovals: (try? store.proposals(states: ["pending"]).count) ?? 0, musicPending: musicPendingCache, musicImportDisabled: musicImportDisabled,
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

    private var backlogCache: (at: Double, value: (albums: Int, bytes: Int64, settling: Int, needsTagging: Int, needsTaggingTracks: Int, auditing: Int))?

    /// Cheap backlog figures from the album summaries (one query), cached briefly. The planner's exact
    /// per-track plan is only run when a batch is previewed or started.
    private func backlogSummary() -> (albums: Int, bytes: Int64, settling: Int, needsTagging: Int, needsTaggingTracks: Int, auditing: Int) {
        let now = Date().timeIntervalSince1970
        if let c = backlogCache, now - c.at < 10 { return c.value }
        guard let summaries = try? store.albumSummaries() else { return (0, 0, 0, 0, 0, 0) }
        var albums = 0, settling = 0, needsTagging = 0, needsTaggingTracks = 0, auditing = 0; var bytes: Int64 = 0
        for s in summaries where !s.ignored && (s.mirrored < s.tracks || s.stale > 0) {
            if settings.requireMusicBrainz {
                if s.untagged > 0 { needsTagging += 1; needsTaggingTracks += s.untagged; continue }
                if s.unaudited > 0 { auditing += 1; continue }
            }
            let wait = Double(max(settings.fileSettleSeconds, settings.albumSettleSeconds)) - (now - s.lastChange)
            if s.minObservations < 2 || wait > 0 { settling += 1; continue }
            albums += 1
            bytes += s.tracks > 0 ? Int64(Double(s.bytes) * Double(s.tracks - s.mirrored) / Double(s.tracks)) : 0
        }
        let value = (albums, bytes, settling, needsTagging, needsTaggingTracks, auditing)
        backlogCache = (now, value)
        return value
    }

    public func artists() -> [ArtistRow] {
        ((try? store.artistSummaries()) ?? []).map {
            ArtistRow(dir: $0.artistDir, name: $0.displayName, albums: $0.albums, tracks: $0.tracks, bytes: $0.bytes, mirrored: $0.mirrored, pinned: $0.pinned, status: $0.status, untagged: $0.untagged, stale: $0.stale)
        }
    }

    public func albums(artist: String) -> [AlbumRow] {
        ((try? store.albumSummaries(artist: artist)) ?? []).map {
            AlbumRow(artistDir: $0.key.artistDir, albumDir: $0.key.albumDir, name: $0.displayAlbum ?? ($0.key.albumDir.isEmpty ? "(loose files)" : $0.key.albumDir),
                     tracks: $0.tracks, bytes: $0.bytes, mirrored: $0.mirrored, lossless: $0.losslessTracks, lossy: $0.lossyTracks,
                     status: $0.mirrored == 0 ? "none" : ($0.mirrored == $0.tracks ? "complete" : "partial"), firstSeen: $0.firstSeen, untagged: $0.untagged, unaudited: $0.unaudited, stale: $0.stale, ignored: $0.ignored)
        }
    }

    func makePlanner(_ profile: Profile) -> Planner {
        Planner(store: store, profile: profile, fileSettleSeconds: settings.fileSettleSeconds, albumSettleSeconds: settings.albumSettleSeconds,
                requireMusicBrainz: settings.requireMusicBrainz, tagDerivedPaths: settings.tagDerivedPaths)
    }

    public func preview(_ selection: Selection) throws -> PlanPreview {
        guard let profile = Profile.named(settings.profileID) else { throw CocoaError(.featureUnsupported) }
        let planner = makePlanner(profile)
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
                           skipped: plan.ineligible.filter { $0.1 == .allSkipped }.count,
                           needsTagging: plan.ineligible.filter { if case .needsTagging = $0.1 { return true }; return false }.count,
                           auditing: plan.ineligible.filter { $0.1 == .auditing }.count,
                           ignored: plan.ineligible.filter { $0.1 == .ignored }.count, estimatedSeconds: seconds)
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
        else { sql += " AND level != 'debug'" }   // routine chatter only on request
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
