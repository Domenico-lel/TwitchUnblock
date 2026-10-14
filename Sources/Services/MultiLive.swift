import AVFoundation
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Multi-live : jusqu'à quatre directs côte à côte.
//
//  MultiLive garde la sélection (sur l'appareil) ; MultiLiveSession tient un
//  lecteur par direct le temps de la mosaïque — hors des vues, pour qu'une
//  rotation (côte à côte ↔ les uns sous les autres) ne relance rien. Le son
//  ne vient que d'un direct à la fois.
// ═══════════════════════════════════════════════════════════════════════════

struct MultiLiveEntry: Codable, Equatable, Identifiable {
    let login: String
    let name: String
    var id: String { login }
}

@MainActor
final class MultiLive: ObservableObject {
    static let shared = MultiLive()
    static let max = 4

    @Published private(set) var entries: [MultiLiveEntry] = []
    private let key = "multi_live"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([MultiLiveEntry].self, from: data) {
            entries = Array(list.prefix(Self.max))
        }
    }

    var isFull: Bool { entries.count >= Self.max }
    func contains(_ login: String) -> Bool { entries.contains { $0.login == login.lowercased() } }

    /// Ajoute (false si la liste est pleine) ; déjà là, rien ne change.
    @discardableResult
    func add(_ login: String, name: String) -> Bool {
        let l = login.trimmingCharacters(in: .whitespaces).lowercased()
        guard !l.isEmpty else { return false }
        if contains(l) { return true }
        guard !isFull else { return false }
        entries.append(MultiLiveEntry(login: l, name: name.isEmpty ? l : name))
        save()
        return true
    }

    /// Ajoute, ou retire s'il y est déjà. false si la liste est pleine.
    @discardableResult
    func toggle(_ login: String, name: String) -> Bool {
        if contains(login) { remove(login); return true }
        return add(login, name: name)
    }

    func remove(_ login: String) {
        entries.removeAll { $0.login == login.lowercased() }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Une qualité qui tient à plusieurs : 1080p seul, 720p à deux, 480p
    /// au-delà — ou la qualité préférée si elle est plus basse (plafond).
    /// La plus haute à cette hauteur ou en dessous, sinon la plus basse.
    nonisolated static func pick(_ links: QualityLinks, count: Int,
                                 variants: [String: VariantInfo] = [:]) -> URL? {
        let rule = count <= 1 ? 1080 : count == 2 ? 720 : 480
        let pref = UserDefaults.standard.string(forKey: "cfg_quality_pref") ?? "source"
        let want = Int(pref).map { min($0, rule) } ?? rule
        let video = links.keys.filter { !isAudioQuality($0) }
        let key: String? = video.isEmpty ? links.keys.first
            : preferredQualityKey(video, pref: String(want), variants: variants)
        return key.flatMap { links[$0] }.flatMap { URL(string: $0) }
    }
}

// MARK: – Un direct de la mosaïque
@MainActor
final class MultiTileModel: ObservableObject {
    enum Phase { case loading, playing, offline, failed }

    let login: String
    let player = AVPlayer()
    /// Pause pub à l'écran (bandeau de la tuile), son coupé le temps qu'elle
    /// dure — seule la tuile qui a le son en a un à couper.
    let adBreaks = AdBreakWatcher()
    @Published private(set) var phase: Phase = .loading
    /// Identifiant Twitch de la chaîne (emotes et badges de son chat).
    @Published private(set) var channelId: String?

    private var task: Task<Void, Never>?
    private var observers: [NSKeyValueObservation] = []
    private var count = 2
    /// Relances après une coupure, remises à zéro dès que l'image revient.
    private var restarts = 0
    /// Session web à donner à getLive (abonné sans pub, voir AppStore).
    private let accountToken: (String) -> String?

    init(login: String, accountToken: @escaping (String) -> String? = { _ in nil }) {
        self.login = login
        self.accountToken = accountToken
        player.isMuted = true
        adBreaks.attach(player)
    }

    func start(count: Int) {
        self.count = count
        task?.cancel()
        stopMedia()
        phase = .loading
        let login = self.login
        let web = accountToken(login)
        task = Task { [weak self] in
            let data = await getLive(channelName: login, webToken: web,
                                     integrity: web.map { dropsIntegrity(for: $0) })
            guard let self, !Task.isCancelled else { return }
            if let id = data.userId { self.channelId = id }
            guard let links = data.links, !links.isEmpty,
                  let url = MultiLive.pick(links, count: count, variants: data.variants) else {
                let gone = data.error == "offline" || data.error == "Streamer introuvable"
                self.phase = gone ? .offline : .failed
                return
            }
            // Même fabrique que les autres lecteurs : audio spatial, pauses pub.
            let item = VodUnmuteLoader.playerItem(url: url)
            self.observe(item)
            self.player.replaceCurrentItem(with: item)
            self.player.play()
        }
    }

    func retry() {
        restarts = 0
        start(count: count)
    }

    func stop() {
        task?.cancel()
        task = nil
        stopMedia()
        adBreaks.detach()
    }

    private func stopMedia() {
        observers = []
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func observe(_ item: AVPlayerItem) {
        observers = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed, let self else { return }
                Task { @MainActor in self.interrupted() }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                guard player.timeControlStatus == .playing, let self else { return }
                Task { @MainActor in self.playing() }
            },
        ]
    }

    private func playing() {
        phase = .playing
        restarts = 0
    }

    /// Coupure : on redemande les liens, trois fois au plus.
    private func interrupted() {
        restarts += 1
        guard restarts <= 3 else { phase = .failed; return }
        phase = .loading
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.start(count: self.count)
        }
    }
}

// MARK: – Les lecteurs de la mosaïque
@MainActor
final class MultiLiveSession: ObservableObject {
    @Published private(set) var tiles: [String: MultiTileModel] = [:]
    /// Direct qui a le son.
    @Published var audible: String? { didSet { applyAudio() } }
    /// Session web à donner à getLive pour une chaîne (AppStore).
    var accountToken: (String) -> String? = { _ in nil }

    /// Un lecteur par direct choisi : ajoutés, retirés.
    func sync(_ entries: [MultiLiveEntry]) {
        let wanted = Set(entries.map(\.login))
        for (login, model) in tiles where !wanted.contains(login) {
            model.stop()
            tiles[login] = nil
        }
        for entry in entries where tiles[entry.login] == nil {
            let model = MultiTileModel(login: entry.login, accountToken: accountToken)
            tiles[entry.login] = model
            model.start(count: entries.count)
        }
        if audible.map({ !wanted.contains($0) }) ?? true { audible = entries.first?.login }
        applyAudio()
    }

    func stopAll() {
        tiles.values.forEach { $0.stop() }
        tiles = [:]
    }

    private func applyAudio() {
        for (login, model) in tiles {
            model.player.isMuted = login != audible
            // En pause pub, la tuile qui a le son est recoupée au tour suivant.
            model.adBreaks.audioTakenOver()
        }
    }
}
