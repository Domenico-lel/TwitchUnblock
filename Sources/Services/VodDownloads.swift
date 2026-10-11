import Foundation
import UIKit
import UserNotifications

// ═══════════════════════════════════════════════════════════════════════════
//  VODs téléchargées pour être regardées hors ligne.
//
//  On télécharge un passage (de tel instant à tel autre, ou toute la VOD)
//  dans la qualité choisie : les segments de la playlist qui couvrent ce
//  passage, posés dans un dossier avec une playlist locale, puis lus par le
//  mini-serveur de l'app (OfflineServer).
//
//  Les segments passent par une session de téléchargement d'arrière-plan
//  d'iOS (VodDownloader) : ils continuent de venir app en arrière-plan, ou
//  fermée par iOS. Si on la ferme en la balayant, iOS annule tout : ce qui
//  manque est redemandé au retour, sans retélécharger ce qui est là.
//
//  Passages coupés pour musique protégée : un jour ou deux après le live, le
//  CDN de Twitch garde encore le son d'origine (« N.ts » à la place de
//  « N-muted.ts », comme pour VodUnmuteLoader). S'il existe, c'est lui qui
//  est téléchargé ; sinon, la version muette.
//
//  Le chat du passage peut être gardé avec (VodChatArchive), pour être
//  rejoué hors ligne ; un téléchargement fini s'exporte en un seul fichier.
// ═══════════════════════════════════════════════════════════════════════════

struct VodDownload: Identifiable, Codable, Equatable {
    enum State: String, Codable { case downloading, paused, done, failed }

    let id: String
    let vodId: String
    let title: String
    let streamer: String
    let thumbnail: String
    let quality: String
    /// Playlist de la qualité choisie (pour reprendre un téléchargement).
    let playlist: String
    let restoreAudio: Bool
    /// Passage demandé, en secondes dans la VOD.
    let start: Double
    let end: Double
    let created: Date
    var total = 0
    var done = 0
    var bytes: Int64 = 0
    /// Secondes de son coupé rétablies, et restées muettes.
    var restored: Double = 0
    var muted: Double = 0
    var state: State = .downloading
    /// Chat gardé avec la vidéo : demandé, et messages gardés (nil tant qu'il
    /// n'est pas fini).
    var withChat: Bool? = nil
    var chatCount: Int? = nil

    var duration: Double { max(0, end - start) }
    var progress: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}

/// Ce qu'il faut pour proposer le téléchargement de la VOD en cours.
struct VodDownloadContext {
    let vodId: String
    let title: String
    let streamer: String
    let thumbnail: String
    /// Playlists par qualité (adresses directes, pas `tuunmute://`).
    let links: QualityLinks
    /// Position de lecture actuelle, en secondes.
    let position: Double
}

// MARK: – Plan : les segments d'un passage
/// Gardé dans le dossier du téléchargement (plan.json) : de quoi reprendre,
/// et finir, même après un redémarrage de l'app par iOS.
struct VodDownloadPlan: Codable {
    struct Segment: Codable {
        let index: Int
        let url: URL
        /// Son d'origine d'un passage coupé (peut avoir disparu du CDN).
        let original: URL?
        /// Instant de la VOD où il commence.
        let start: Double
        let duration: Double
        let discontinuity: Bool

        var ext: String { url.pathExtension.isEmpty ? "ts" : url.pathExtension }
        /// Le segment (son d'origine pour un passage coupé), et sa version muette.
        var fileName: String { "seg_\(String(format: "%05d", index)).\(ext)" }
        var mutedFileName: String { "seg_\(String(format: "%05d", index)).muted.\(ext)" }
    }
    var segments: [Segment] = []
    /// Segment d'initialisation (#EXT-X-MAP), pour les playlists en fMP4.
    var map: URL?
    /// Durée totale de la VOD (toute la playlist).
    var vodDuration: Double = 0
    /// Originaux des passages coupés encore servis (sondé au départ).
    var useOriginals = false

    var mapFileName: String? { map.map { "init." + ($0.pathExtension.isEmpty ? "mp4" : $0.pathExtension) } }
    var fileCount: Int { segments.count + (map == nil ? 0 : 1) }

    static func fetch(_ playlist: URL) async -> String? {
        guard let (data, resp) = try? await URLSession.shared.data(from: playlist),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.hasPrefix("#EXTM3U") ? text : nil
    }

    /// Segments qui recouvrent [start, end] (toute la VOD si end ≤ start).
    static func make(_ text: String, base: URL, from start: Double, to end: Double) -> VodDownloadPlan {
        var plan = VodDownloadPlan()
        var clock = 0.0, pending = 0.0, discontinuity = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                pending = Double(line.dropFirst(8).split(separator: ",").first ?? "") ?? 0
                continue
            }
            if line.hasPrefix("#EXT-X-DISCONTINUITY") { discontinuity = true; continue }
            if line.hasPrefix("#EXT-X-MAP:"),
               let r = line.range(of: #"URI="([^"]+)""#, options: .regularExpression) {
                let uri = line[r].dropFirst(5).dropLast()
                plan.map = URL(string: String(uri), relativeTo: base)?.absoluteURL
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let abs = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            let segStart = clock
            clock += pending
            if end <= start || (clock > start && segStart < end) {
                var url = abs
                var original: URL? = nil
                let s = abs.absoluteString
                // « N-muted.ts », ou « N-muted.mp4 » pour les VODs en fMP4.
                if let r = s.range(of: #"-(un)?muted\.(ts|mp4)"#, options: .regularExpression) {
                    let ext = s[r].hasSuffix(".mp4") ? "mp4" : "ts"
                    // « -unmuted » n'existe pas sur le CDN : la version muette sert de repli.
                    url = URL(string: s.replacingCharacters(in: r, with: "-muted.\(ext)")) ?? abs
                    original = URL(string: s.replacingCharacters(in: r, with: ".\(ext)"))
                }
                plan.segments.append(Segment(index: plan.segments.count, url: url, original: original,
                                             start: segStart, duration: pending,
                                             discontinuity: discontinuity && !plan.segments.isEmpty))
            }
            pending = 0
            discontinuity = false
        }
        plan.vodDuration = clock
        return plan
    }
}

// MARK: – Gestionnaire
@MainActor
final class VodDownloads: ObservableObject {
    static let shared = VodDownloads()

    @Published private(set) var items: [VodDownload] = []
    /// Préparations en cours (playlist, sondage des originaux, mise en file).
    private var preparing: [String: Task<Void, Never>] = [:]
    /// Chats en cours de téléchargement.
    private var chats: [String: Task<Void, Never>] = [:]
    /// Fichiers perdus pour de bon (après les essais), par téléchargement.
    private var failures: [String: Int] = [:]
    private var unsaved = 0

    /// Application Support/Downloads, exclu des sauvegardes iCloud.
    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }
    nonisolated static func folder(_ id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }
    /// Fichiers exportés pour le partage : temporaires, vidés au lancement.
    nonisolated static var exportsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    }
    private var indexURL: URL { Self.directory.appendingPathComponent("index.json") }

    private init() {
        var dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([VodDownload].self, from: data) {
            items = list
        }
        try? FileManager.default.removeItem(at: Self.exportsDirectory)
        VodDownloader.shared.activate()
    }

    private func save() {
        unsaved = 0
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
    }

    private func update(_ id: String, _ change: (inout VodDownload) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    private func item(_ id: String) -> VodDownload? { items.first { $0.id == id } }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    // MARK: Actions
    func start(_ ctx: VodDownloadContext, quality: String, start: Double, end: Double,
               restoreAudio: Bool, withChat: Bool) {
        guard let playlist = ctx.links[quality] else { return }
        let safeQuality = quality.filter { $0.isLetter || $0.isNumber }
        let id = "\(ctx.vodId)_\(Int(start))_\(Int(end))_\(safeQuality)"
        if item(id) == nil {
            var new = VodDownload(id: id, vodId: ctx.vodId, title: ctx.title, streamer: ctx.streamer,
                                  thumbnail: ctx.thumbnail, quality: quality, playlist: playlist,
                                  restoreAudio: restoreAudio, start: start, end: end, created: Date())
            // Une VOD supprimée retrouvée n'a plus de chat.
            new.withChat = withChat && Self.hasChat(ctx.vodId)
            items.insert(new, at: 0)
        }
        resume(id)
    }

    func resume(_ id: String) {
        guard let current = item(id), current.state != .done else { return }
        update(id) { $0.state = .downloading }
        failures[id] = 0
        save()
        prepare(id)
    }

    func pause(_ id: String) {
        stopWork(id)
        update(id) { $0.state = .paused }
        save()
    }

    func delete(_ id: String) {
        stopWork(id)
        try? FileManager.default.removeItem(at: Self.folder(id))
        items.removeAll { $0.id == id }
        save()
    }

    private func stopWork(_ id: String) {
        preparing[id]?.cancel()
        preparing[id] = nil
        chats[id]?.cancel()
        chats[id] = nil
        VodDownloader.shared.cancel(item: id)
    }

    /// Au lancement et au retour dans l'app : ce qui manque est redemandé
    /// (app fermée en la balayant, réseau perdu…) et les chats inachevés
    /// repris. Les fichiers encore attendus par iOS ne sont pas redemandés.
    func reconcile() {
        for d in items where d.state == .downloading { prepare(d.id) }
        for d in items where d.state != .paused && d.withChat == true && d.chatCount == nil {
            startChat(d.id)
        }
    }

    /// Lecture hors ligne : la playlist locale, servie par OfflineServer.
    func playback(_ item: VodDownload) async -> RecoveredVod? {
        guard item.state == .done, let base = await OfflineServer.shared.baseURL() else { return nil }
        let url = base.appendingPathComponent(item.id).appendingPathComponent("index.m3u8")
        return RecoveredVod(streamID: "offline-\(item.id)", title: item.title,
                            streamer: item.streamer, links: [item.quality: url.absoluteString])
    }

    // MARK: Préparation
    private func prepare(_ id: String) {
        guard preparing[id] == nil else { return }
        preparing[id] = Task { [weak self] in
            await self?.runPrepare(id)
            self?.preparing[id] = nil
        }
    }

    private func runPrepare(_ id: String) async {
        guard let current = item(id) else { return }
        let folder = Self.folder(id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var plan = Self.loadPlan(id)
        if plan == nil {
            logger.info("DOWNLOAD", "Téléchargement…", "\(current.title) · \(current.quality)")
            guard let url = URL(string: current.playlist), let text = await VodDownloadPlan.fetch(url) else {
                fail(id)
                return
            }
            var made = VodDownloadPlan.make(text, base: url, from: current.start, to: current.end)
            guard !made.segments.isEmpty else { fail(id); return }
            if current.restoreAudio { made.useOriginals = await Self.originalsAvailable(made) }
            Self.savePlan(made, id)
            plan = made
        }
        guard let plan, !Task.isCancelled else { return }

        // Déjà là (reprise) : compté, pas redemandé.
        let (present, bytes) = Self.scan(plan, folder: folder)
        update(id) {
            $0.total = plan.fileCount
            $0.done = present
            $0.bytes = bytes
        }
        if current.withChat == true, current.chatCount == nil { startChat(id) }
        if present >= plan.fileCount { finalize(id, plan); return }

        let pending = await VodDownloader.shared.pendingFiles(item: id)
        guard !Task.isCancelled, item(id)?.state == .downloading else { return }
        let jobs = Self.missingJobs(plan, item: id, folder: folder, skipping: pending)
        VodDownloader.shared.enqueue(jobs)
        if !jobs.isEmpty { logger.info("DOWNLOAD", "Fichiers demandés", "\(jobs.count) · \(id)") }
    }

    /// Ce qui manque sur le disque et n'est pas déjà attendu.
    nonisolated private static func missingJobs(_ plan: VodDownloadPlan, item: String, folder: URL,
                                                skipping pending: Set<String>) -> [VodDownloader.Job] {
        let fm = FileManager.default
        let has = { (name: String) in fm.fileExists(atPath: folder.appendingPathComponent(name).path) }
        var jobs: [VodDownloader.Job] = []
        if let map = plan.map, let name = plan.mapFileName, !has(name), !pending.contains(name) {
            jobs.append(.init(item: item, kind: .initSegment, url: map, fallback: nil, fileName: name))
        }
        for s in plan.segments where !has(s.fileName) && !has(s.mutedFileName)
            && !pending.contains(s.fileName) && !pending.contains(s.mutedFileName) {
            if s.original == nil {
                jobs.append(.init(item: item, kind: .normal, url: s.url, fallback: nil, fileName: s.fileName))
            } else if plan.useOriginals, let original = s.original {
                jobs.append(.init(item: item, kind: .original, url: original, fallback: s.url, fileName: s.fileName))
            } else {
                jobs.append(.init(item: item, kind: .muted, url: s.url, fallback: nil, fileName: s.mutedFileName))
            }
        }
        return jobs
    }

    // MARK: Nouvelles du téléchargeur
    func fileDone(item id: String, size: Int64) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .downloading else { return }
        items[i].done += 1
        items[i].bytes += size
        unsaved += 1
        if unsaved >= 25 { save() }
        settleIfFinished(id)
    }

    func fileFailed(item id: String) {
        failures[id, default: 0] += 1
        settleIfFinished(id)
    }

    /// Plus rien d'attendu : fini (playlist écrite) ou interrompu (à reprendre).
    private func settleIfFinished(_ id: String) {
        guard let d = item(id), d.state == .downloading, preparing[id] == nil,
              d.done + (failures[id] ?? 0) >= d.total else { return }
        Task {
            guard let plan = Self.loadPlan(id) else { fail(id); return }
            let (present, bytes) = Self.scan(plan, folder: Self.folder(id))
            if present >= plan.fileCount { finalize(id, plan); return }
            // Compteurs faussés (fichier reçu deux fois…) : le disque fait foi.
            update(id) { $0.done = present; $0.bytes = bytes }
            if await VodDownloader.shared.pendingFiles(item: id).isEmpty { fail(id) }
        }
    }

    private func fail(_ id: String) {
        guard item(id)?.state == .downloading else { return }
        update(id) { $0.state = .failed }
        save()
        logger.warn("DOWNLOAD", "Téléchargement interrompu", id)
    }

    private func finalize(_ id: String, _ plan: VodDownloadPlan) {
        guard let d = item(id), d.state != .done else { return }
        let folder = Self.folder(id)
        let fm = FileManager.default
        var names: [Int: String] = [:]
        var restored = 0.0, muted = 0.0
        for s in plan.segments {
            if fm.fileExists(atPath: folder.appendingPathComponent(s.fileName).path) {
                names[s.index] = s.fileName
                if s.original != nil { restored += s.duration }
            } else if fm.fileExists(atPath: folder.appendingPathComponent(s.mutedFileName).path) {
                names[s.index] = s.mutedFileName
                muted += s.duration
            }
        }
        do {
            try Self.writePlaylist(plan, folder: folder, names: names)
        } catch {
            fail(id)
            return
        }
        update(id) {
            $0.state = .done
            $0.done = $0.total
            $0.restored = restored
            $0.muted = muted
        }
        save()
        logger.success("DOWNLOAD", "Téléchargement terminé", d.title)
        let lang = Lang(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "en") ?? .en
        let content = UNMutableNotificationContent()
        content.title = translate("dl_done_notif", lang)
        content.body = d.title
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "download-\(id)", content: content, trigger: nil))
    }

    // MARK: Chat
    nonisolated static func hasChat(_ vodId: String) -> Bool { !vodId.isEmpty && vodId.allSatisfy(\.isNumber) }

    private func startChat(_ id: String) {
        guard chats[id] == nil, let d = item(id), d.withChat == true, d.chatCount == nil,
              let plan = Self.loadPlan(id), let first = plan.segments.first, let last = plan.segments.last else { return }
        let from = first.start, to = last.start + last.duration
        chats[id] = Task { [weak self] in
            let count = await VodChatArchive.download(vodId: d.vodId, from: from, to: to, into: VodDownloads.folder(id))
            guard let self, !Task.isCancelled else { return }
            self.chats[id] = nil
            guard let count else { return }
            self.update(id) { $0.chatCount = count }
            self.save()
        }
    }

    // MARK: Export
    /// Un seul fichier (.ts, ou .mp4 pour les VODs en fMP4), pour Fichiers,
    /// AirDrop ou VLC. Temporaire : effacé après le partage, ou au lancement.
    func export(_ d: VodDownload) async -> URL? {
        guard d.state == .done, let plan = Self.loadPlan(d.id) else { return nil }
        let name = Self.exportName(d, ext: plan.map == nil ? "ts" : "mp4")
        let folder = Self.folder(d.id)
        return await Task.detached(priority: .userInitiated) {
            VodDownloads.concatenate(plan, folder: folder, name: name)
        }.value
    }

    nonisolated private static func concatenate(_ plan: VodDownloadPlan, folder: URL, name: String) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        let out = exportsDirectory.appendingPathComponent(name)
        try? fm.removeItem(at: out)
        guard fm.createFile(atPath: out.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: out) else { return nil }
        defer { try? handle.close() }
        var files: [String] = []
        if let mapName = plan.mapFileName { files.append(mapName) }
        for s in plan.segments {
            files.append(fm.fileExists(atPath: folder.appendingPathComponent(s.fileName).path) ? s.fileName : s.mutedFileName)
        }
        for file in files {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(file), options: .mappedIfSafe) else { continue }
            do { try handle.write(contentsOf: data) } catch { return nil }
        }
        return out
    }

    nonisolated private static func exportName(_ d: VodDownload, ext: String) -> String {
        let clean = { (s: String) in
            String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " -_".unicodeScalars.contains($0) })
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " ", with: "_")
                .prefix(60)
        }
        let clock = { (t: Double) in dlClock(t).replacingOccurrences(of: ":", with: "-") }
        let parts = [String(clean(d.streamer)), String(clean(d.title)), "\(clock(d.start))_\(clock(d.end))",
                     String(clean(d.quality))].filter { !$0.isEmpty }
        return parts.joined(separator: "_") + ".\(ext)"
    }

    // MARK: Fichiers
    nonisolated private static func planURL(_ id: String) -> URL { folder(id).appendingPathComponent("plan.json") }

    nonisolated private static func loadPlan(_ id: String) -> VodDownloadPlan? {
        guard let data = try? Data(contentsOf: planURL(id)) else { return nil }
        return try? JSONDecoder().decode(VodDownloadPlan.self, from: data)
    }

    nonisolated private static func savePlan(_ plan: VodDownloadPlan, _ id: String) {
        if let data = try? JSONEncoder().encode(plan) { try? data.write(to: planURL(id), options: .atomic) }
    }

    /// Fichiers déjà là (segment, ou sa version muette) et leur taille.
    nonisolated private static func scan(_ plan: VodDownloadPlan, folder: URL) -> (Int, Int64) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var sizes: [String: Int64] = [:]
        for u in urls { sizes[u.lastPathComponent] = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var present = 0
        var bytes: Int64 = 0
        if let name = plan.mapFileName, let size = sizes[name] { present += 1; bytes += size }
        for s in plan.segments {
            if let size = sizes[s.fileName] ?? sizes[s.mutedFileName] { present += 1; bytes += size }
        }
        return (present, bytes)
    }

    /// Son d'origine encore là ? Quatre premiers passages coupés : tous
    /// refusés, la VOD est trop ancienne — inutile d'essayer les autres.
    nonisolated private static func originalsAvailable(_ plan: VodDownloadPlan) async -> Bool {
        for s in plan.segments.lazy.filter({ $0.original != nil }).prefix(4) {
            guard let original = s.original else { continue }
            var req = URLRequest(url: original, timeoutInterval: 6)
            req.httpMethod = "HEAD"
            if (try? await URLSession.shared.data(for: req).1 as? HTTPURLResponse)?.statusCode == 200 { return true }
        }
        return false
    }

    nonisolated private static func writePlaylist(_ plan: VodDownloadPlan, folder: URL, names: [Int: String]) throws {
        let target = Int((plan.segments.map(\.duration).max() ?? 10).rounded(.up))
        let mapName = plan.mapFileName
        var out = "#EXTM3U\n#EXT-X-VERSION:\(mapName != nil ? 7 : 3)\n#EXT-X-TARGETDURATION:\(max(1, target))\n"
        out += "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        if let mapName { out += "#EXT-X-MAP:URI=\"\(mapName)\"\n" }
        for s in plan.segments {
            guard let name = names[s.index] else { continue }
            if s.discontinuity { out += "#EXT-X-DISCONTINUITY\n" }
            out += String(format: "#EXTINF:%.3f,\n", s.duration) + name + "\n"
        }
        out += "#EXT-X-ENDLIST\n"
        try out.write(to: folder.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
    }
}

// MARK: – Téléchargements en arrière-plan
/// Session de téléchargement d'arrière-plan d'iOS : un fichier par tâche,
/// rangé dans le dossier du téléchargement dès qu'il arrive, puis
/// VodDownloads prévenu. iOS relance l'app en arrière-plan pour livrer les
/// fichiers arrivés pendant qu'elle était fermée (AppDelegate).
final class VodDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = VodDownloader()
    static let identifier = "com.mxfia19.TwitchUnblock.downloads"

    enum Kind: String { case initSegment = "i", normal = "n", original = "o", muted = "m" }

    struct Job {
        let item: String
        let kind: Kind
        let url: URL
        /// Original refusé : la version muette à demander à la place.
        let fallback: URL?
        let fileName: String
    }

    /// Rendu à iOS une fois les événements d'arrière-plan traités.
    var backgroundCompletion: (() -> Void)?

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "tu.downloads"
        return q
    }()
    private var session: URLSession!
    // Tenus sur `queue` seulement.
    private var finished: [Int: Int64] = [:]
    private var refused: [Int: Int] = [:]
    private var retries: [String: Int] = [:]

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    /// Recréer la session au lancement : iOS lui rend les tâches en cours.
    func activate() {}

    func enqueue(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        queue.addOperation { [self] in jobs.forEach(start) }
    }

    private func start(_ job: Job) {
        let task = session.downloadTask(with: job.url)
        task.taskDescription = Self.describe(job)
        task.resume()
    }

    func cancel(item: String) {
        session.getAllTasks { tasks in
            for t in tasks where Self.parse(t.taskDescription)?.item == item { t.cancel() }
        }
    }

    /// Fichiers encore attendus pour ce téléchargement.
    func pendingFiles(item: String) async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap { t -> String? in
            guard t.state == .running || t.state == .suspended,
                  let job = Self.parse(t.taskDescription), job.item == item else { return nil }
            return job.fileName
        })
    }

    // MARK: Description d'une tâche : « téléchargement|type|fichier|repli »
    private static func describe(_ job: Job) -> String {
        [job.item, job.kind.rawValue, job.fileName, job.fallback?.absoluteString ?? ""].joined(separator: "|")
    }

    private static func parse(_ text: String?) -> Job? {
        guard let parts = text?.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false),
              parts.count == 4, let kind = Kind(rawValue: String(parts[1])) else { return nil }
        return Job(item: String(parts[0]), kind: kind, url: URL(fileURLWithPath: "/"),
                   fallback: URL(string: String(parts[3])), fileName: String(parts[2]))
    }

    /// « seg_00012.ts » → « seg_00012.muted.ts ».
    private static func mutedName(_ name: String) -> String {
        let ns = name as NSString
        return ns.deletingPathExtension + ".muted." + ns.pathExtension
    }

    // MARK: URLSessionDownloadDelegate
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let job = Self.parse(downloadTask.taskDescription) else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { refused[downloadTask.taskIdentifier] = code; return }
        // À ranger avant de rendre la main : iOS efface le fichier ensuite.
        let dest = VodDownloads.folder(job.item).appendingPathComponent(job.fileName)
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: location, to: dest)
            let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
            finished[downloadTask.taskIdentifier] = size
        } catch {
            refused[downloadTask.taskIdentifier] = -1   // dossier supprimé entre-temps
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = Self.parse(task.taskDescription) else { return }
        let key = task.taskDescription ?? ""
        if let size = finished.removeValue(forKey: task.taskIdentifier) {
            retries[key] = nil
            Task { @MainActor in VodDownloads.shared.fileDone(item: job.item, size: size) }
            return
        }
        if let code = refused.removeValue(forKey: task.taskIdentifier) {
            if code == -1 { return }
            // Son d'origine refusé (effacé du CDN) : la version muette.
            if job.kind == .original, let fallback = job.fallback {
                start(Job(item: job.item, kind: .muted, url: fallback, fallback: nil,
                          fileName: Self.mutedName(job.fileName)))
                return
            }
            Task { @MainActor in VodDownloads.shared.fileFailed(item: job.item) }
            return
        }
        if (error as? URLError)?.code == .cancelled { return }
        // Erreur réseau : trois nouveaux essais.
        let count = (retries[key] ?? 0) + 1
        retries[key] = count
        if count <= 3, let url = task.originalRequest?.url {
            start(Job(item: job.item, kind: job.kind, url: url, fallback: job.fallback, fileName: job.fileName))
        } else {
            retries[key] = nil
            Task { @MainActor in VodDownloads.shared.fileFailed(item: job.item) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
