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
//  Passages coupés pour musique protégée : un jour ou deux après le live, le
//  CDN de Twitch garde encore le son d'origine (« N.ts » à la place de
//  « N-muted.ts », comme pour VodUnmuteLoader). S'il existe, c'est lui qui
//  est téléchargé ; sinon, la version muette.
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
struct VodDownloadPlan {
    struct Segment {
        let index: Int
        let url: URL
        /// Son d'origine d'un passage coupé (peut avoir disparu du CDN).
        let original: URL?
        let duration: Double
        let discontinuity: Bool
    }
    var segments: [Segment] = []
    /// Segment d'initialisation (#EXT-X-MAP), pour les playlists en fMP4.
    var map: URL?
    /// Durée totale de la VOD (toute la playlist).
    var vodDuration: Double = 0

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
                                             duration: pending, discontinuity: discontinuity && !plan.segments.isEmpty))
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
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Coupés par la suspension ou la fermeture de l'app : repris au retour.
    private var interrupted: Set<String> = []

    /// Application Support/Downloads, exclu des sauvegardes iCloud.
    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Downloads", isDirectory: true)
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
            // Interrompus par la fermeture de l'app : en pause, repris au retour.
            for var d in list {
                if d.state == .downloading {
                    d.state = .paused
                    interrupted.insert(d.id)
                }
                items.append(d)
            }
        }
    }

    /// Au retour dans l'app : reprend ce que la suspension (ou la fermeture)
    /// de l'app a coupé. Les fichiers déjà là ne sont pas retéléchargés.
    func resumeInterrupted() {
        let ids = interrupted
        interrupted.removeAll()
        ids.forEach { resume($0) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
    }

    private func update(_ id: String, _ change: (inout VodDownload) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    // MARK: Actions
    func start(_ ctx: VodDownloadContext, quality: String, start: Double, end: Double, restoreAudio: Bool) {
        guard let playlist = ctx.links[quality] else { return }
        let safeQuality = quality.filter { $0.isLetter || $0.isNumber }
        let id = "\(ctx.vodId)_\(Int(start))_\(Int(end))_\(safeQuality)"
        if !items.contains(where: { $0.id == id }) {
            items.insert(VodDownload(id: id, vodId: ctx.vodId, title: ctx.title, streamer: ctx.streamer,
                                     thumbnail: ctx.thumbnail, quality: quality, playlist: playlist,
                                     restoreAudio: restoreAudio, start: start, end: end, created: Date()), at: 0)
        }
        resume(id)
    }

    func resume(_ id: String) {
        guard tasks[id] == nil, let item = items.first(where: { $0.id == id }), item.state != .done else { return }
        update(id) { $0.state = .downloading }
        save()
        tasks[id] = Task { [weak self] in await self?.run(id) }
    }

    func pause(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        update(id) { $0.state = .paused }
        save()
    }

    func delete(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(id, isDirectory: true))
        items.removeAll { $0.id == id }
        save()
    }

    /// Lecture hors ligne : la playlist locale, servie par OfflineServer.
    func playback(_ item: VodDownload) async -> RecoveredVod? {
        guard item.state == .done, let base = await OfflineServer.shared.baseURL() else { return nil }
        let url = base.appendingPathComponent(item.id).appendingPathComponent("index.m3u8")
        return RecoveredVod(streamID: "offline-\(item.id)", title: item.title,
                            streamer: item.streamer, links: [item.quality: url.absoluteString])
    }

    // MARK: Téléchargement
    private func run(_ id: String) async {
        guard let item = items.first(where: { $0.id == id }),
              let playlistURL = URL(string: item.playlist) else { return }
        let folder = Self.directory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Quelques minutes de plus si l'on quitte l'app pendant le téléchargement.
        let background = BackgroundGrace(name: "vod-download-\(id)")
        defer { background.end() }

        logger.info("DOWNLOAD", "Téléchargement…", "\(item.title) · \(item.quality)")
        guard let text = await VodDownloadPlan.fetch(playlistURL) else {
            finish(id, ok: false)
            return
        }
        let plan = VodDownloadPlan.make(text, base: playlistURL, from: item.start, to: item.end)
        guard !plan.segments.isEmpty else { finish(id, ok: false); return }
        update(id) { $0.total = plan.segments.count }

        let result = await Self.fetchAll(plan, into: folder, restoreAudio: item.restoreAudio) { done, bytes in
            await MainActor.run {
                VodDownloads.shared.update(id) { $0.done = done; $0.bytes = bytes }
            }
        }
        if Task.isCancelled { save(); return }
        guard let result else { finish(id, ok: false); return }
        do {
            try Self.writePlaylist(plan, folder: folder, names: result.names, mapName: result.mapName)
        } catch {
            finish(id, ok: false)
            return
        }
        update(id) {
            $0.restored = result.restored
            $0.muted = result.muted
            $0.done = $0.total
        }
        finish(id, ok: true)
    }

    private func finish(_ id: String, ok: Bool) {
        tasks[id] = nil
        update(id) { $0.state = ok ? .done : .failed }
        save()
        guard ok, let item = items.first(where: { $0.id == id }) else {
            logger.warn("DOWNLOAD", "Téléchargement interrompu", id)
            // Coupé hors de l'app (réseau suspendu) : on réessaiera au retour.
            if UIApplication.shared.applicationState != .active { interrupted.insert(id) }
            return
        }
        logger.success("DOWNLOAD", "Téléchargement terminé", item.title)
        let lang = Lang(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "en") ?? .en
        let content = UNMutableNotificationContent()
        content.title = translate("dl_done_notif", lang)
        content.body = item.title
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "download-\(id)", content: content, trigger: nil))
    }

    // MARK: Fichiers
    private struct FetchResult {
        var names: [Int: String]
        var mapName: String?
        var restored: Double
        var muted: Double
    }

    /// Télécharge ce qui manque, trois segments à la fois. nil si un segment
    /// n'a pas pu venir (on reprendra plus tard ce qui manque).
    private nonisolated static func fetchAll(_ plan: VodDownloadPlan, into folder: URL, restoreAudio: Bool,
                                             progress: @escaping @Sendable (Int, Int64) async -> Void) async -> FetchResult? {
        var result = FetchResult(names: [:], mapName: nil, restored: 0, muted: 0)
        if let map = plan.map {
            let name = "init." + (map.pathExtension.isEmpty ? "mp4" : map.pathExtension)
            let dest = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: dest.path) {
                guard await download(map, to: dest) != nil else { return nil }
            }
            result.mapName = name
        }

        // Son d'origine encore là ? Quatre premiers passages coupés d'abord :
        // tous refusés, la VOD est trop ancienne — inutile d'essayer les autres.
        var tryOriginals = false
        if restoreAudio {
            for s in plan.segments.lazy.filter({ $0.original != nil }).prefix(4) {
                if let o = s.original, await head(o) { tryOriginals = true; break }
            }
        }

        var done = 0
        var bytes: Int64 = 0
        var failed = false
        let useOriginals = tryOriginals
        await withTaskGroup(of: (Int, String?, Int64, Bool?).self) { group in
            var next = 0
            for _ in 0 ..< min(3, plan.segments.count) {
                let s = plan.segments[next]
                next += 1
                group.addTask { await fetchOne(s, into: folder, tryOriginal: useOriginals) }
            }
            while let finished = await group.next() {
                let (index, name, size, restored) = finished
                if Task.isCancelled { group.cancelAll(); failed = true; continue }
                guard let name else { failed = true; group.cancelAll(); continue }
                result.names[index] = name
                let duration = plan.segments[index].duration
                if restored == true { result.restored += duration }
                if restored == false { result.muted += duration }
                done += 1
                bytes += size
                await progress(done, bytes)
                if next < plan.segments.count {
                    let s = plan.segments[next]
                    next += 1
                    group.addTask { await fetchOne(s, into: folder, tryOriginal: useOriginals) }
                }
            }
        }
        return failed ? nil : result
    }

    /// Un segment : le fichier déjà là, sinon téléchargé. `restored` : true si
    /// le son d'origine a été pris, false si le passage reste muet, nil pour
    /// un segment normal.
    private nonisolated static func fetchOne(_ s: VodDownloadPlan.Segment, into folder: URL,
                                             tryOriginal: Bool) async -> (Int, String?, Int64, Bool?) {
        let ext = s.url.pathExtension.isEmpty ? "ts" : s.url.pathExtension
        let base = String(format: "seg_%05d", s.index)
        let normal = "\(base).\(ext)"
        let mutedName = "\(base).muted.\(ext)"
        let fm = FileManager.default
        // Reprise : déjà téléchargé.
        for (name, restored) in [(normal, s.original != nil ? true : nil), (mutedName, false)] as [(String, Bool?)] {
            let path = folder.appendingPathComponent(name).path
            if fm.fileExists(atPath: path) {
                let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
                return (s.index, name, size, restored)
            }
        }
        if let original = s.original {
            if tryOriginal, let size = await download(original, to: folder.appendingPathComponent(normal)) {
                return (s.index, normal, size, true)
            }
            if let size = await download(s.url, to: folder.appendingPathComponent(mutedName)) {
                return (s.index, mutedName, size, false)
            }
            return (s.index, nil, 0, nil)
        }
        if let size = await download(s.url, to: folder.appendingPathComponent(normal)) {
            return (s.index, normal, size, nil)
        }
        return (s.index, nil, 0, nil)
    }

    /// Taille du fichier téléchargé, nil s'il n'existe pas ou n'a pas pu venir
    /// (trois essais pour une erreur réseau, aucun pour un 403/404).
    private nonisolated static func download(_ url: URL, to dest: URL) async -> Int64? {
        for attempt in 0 ..< 3 {
            if Task.isCancelled { return nil }
            if let (tmp, resp) = try? await URLSession.shared.download(from: url) {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    try? FileManager.default.removeItem(at: dest)
                    guard (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { return nil }
                    let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value
                    return size ?? 0
                }
                try? FileManager.default.removeItem(at: tmp)
                if code == 403 || code == 404 { return nil }
            }
            try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
        }
        return nil
    }

    private nonisolated static func head(_ url: URL) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "HEAD"
        let code = (try? await URLSession.shared.data(for: req).1 as? HTTPURLResponse)?.statusCode
        return code == 200
    }

    private nonisolated static func writePlaylist(_ plan: VodDownloadPlan, folder: URL,
                                                  names: [Int: String], mapName: String?) throws {
        let target = Int((plan.segments.map(\.duration).max() ?? 10).rounded(.up))
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

/// Temps d'arrière-plan demandé à iOS, rendu à la fin (ou quand iOS le reprend).
private final class BackgroundGrace {
    private var id: UIBackgroundTaskIdentifier = .invalid

    @MainActor
    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        let current = id
        id = .invalid
        guard current != .invalid else { return }
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(current) }
    }
}
