import AVFoundation

// ═══════════════════════════════════════════════════════════════════════════
//  Son des passages coupés (musique protégée)
//
//  Twitch coupe le son de certains passages des VODs : la playlist pointe
//  alors vers « N-muted.ts » (son muet), ou vers « N-unmuted.ts », que le CDN
//  refuse. Pendant un jour ou deux après la diffusion, l'original « N.ts »,
//  avec le son, reste pourtant servi — ensuite il est effacé (403).
//
//  Tant qu'il est là, on le remet : la playlist passe par ce chargeur (adresse
//  `tuunmute://…`), qui la lit sur le CDN, vérifie chaque passage coupé et
//  remplace ceux dont l'original répond. Les segments, eux, viennent toujours
//  du CDN en direct (adresses absolues) : rien ne transite par nos serveurs.
//
//  VODs en fMP4 : « N-unmuted.mp4 » est servi, lui, et AVEC le son (c'est
//  « N-muted.mp4 » qui est silencieux, et « N.mp4 » est refusé). On le laisse
//  tel quel : seul « -unmuted.ts » est remplacé.
//
//  AirPlay ne sait pas lire ces adresses : quand la lecture part sur un autre
//  écran, on revient à la playlist du CDN (`fallBackForAirPlay`).
// ═══════════════════════════════════════════════════════════════════════════
final class VodUnmuteLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let shared = VodUnmuteLoader()
    static let scheme = "tuunmute"
    /// Résultat d'une playlist réécrite : `url` (adresse du CDN), `restored`
    /// (passages rétablis), `remaining` ([MutedRange] encore muets).
    static let resultNotification = Notification.Name("VodUnmuteResult")

    private let queue = DispatchQueue(label: "twitchunblock.unmute")
    /// Annonce d'une playlist réécrite (voir `resultNotification`).
    private struct Outcome { let restored: Int; let remaining: [MutedRange] }
    /// Playlists déjà réécrites (changement de qualité, retour en arrière),
    /// avec leur annonce (nil : rien de coupé, pas d'annonce).
    private var cache: [String: (data: Data, outcome: Outcome?)] = [:]
    private let lock = NSLock()

    // MARK: Adresses
    /// Ça vaut la peine d'essayer : passages coupés, et VOD assez récente
    /// pour que les originaux existent encore (au-delà, ils sont effacés).
    static func worthTrying(_ m: VodMarkers) -> Bool {
        guard !m.muted.isEmpty else { return false }
        guard let created = m.createdAt else { return true }
        return Date().timeIntervalSince(created) < 4 * 86400
    }

    static func wrap(_ links: QualityLinks) -> QualityLinks {
        links.mapValues { link in
            // L'audio seul n'a jamais d'original : rien à gagner, autant
            // garder la lecture directe (et AirPlay).
            guard link.hasPrefix("https://"), !link.contains("/audio_only/") else { return link }
            return scheme + "://" + link.dropFirst("https://".count)
        }
    }

    static func unwrap(_ url: URL) -> URL? {
        guard url.scheme == scheme else { return url }
        return URL(string: "https://" + url.absoluteString.dropFirst(scheme.count + 3))
    }

    static func unwrap(_ link: String) -> String {
        link.hasPrefix(scheme + "://") ? "https://" + link.dropFirst(scheme.count + 3) : link
    }

    /// Élément de lecture : passe par le bon chargeur pour une adresse maison
    /// (`tuunmute://` : passages coupés ; `tulive://` : direct au plus près).
    static func playerItem(url: URL) -> AVPlayerItem {
        let item: AVPlayerItem
        switch url.scheme {
        case scheme:
            let asset = AVURLAsset(url: url)
            asset.resourceLoader.setDelegate(shared, queue: shared.queue)
            item = AVPlayerItem(asset: asset)
        case LivePlaylistLoader.scheme:
            let asset = AVURLAsset(url: url)
            asset.resourceLoader.setDelegate(LivePlaylistLoader.shared, queue: LivePlaylistLoader.shared.queue)
            item = AVPlayerItem(asset: asset)
        default:
            item = AVPlayerItem(url: url)
        }
        // Réglage « Audio spatial » : tous les lecteurs passent par ici.
        SpatialAudio.apply(to: item)
        keepPitch(item)
        // Pauses pub cousues par Twitch dans un direct (AdBreakMonitor) ; une
        // VOD n'en annonce pas, le collecteur n'y fait rien.
        AdBreakMonitor.attach(to: item)
        return item
    }

    /// Vitesse ≠ 1× (VODs) : voix à la bonne hauteur. C'est le défaut documenté
    /// sur iPhone depuis iOS 15 ; l'écrire le fige, tvOS compris. Ni
    /// `.varispeed` (voix aiguë), ni `.lowQualityZeroLatency` (vitesses
    /// arrondies).
    static func keepPitch(_ item: AVPlayerItem) {
        item.audioTimePitchAlgorithm = .timeDomain
    }

    /// AirPlay en cours : on repasse sur la playlist du CDN, à la même position.
    static func fallBackForAirPlay(_ player: AVPlayer) {
        guard player.isExternalPlaybackActive,
              let asset = player.currentItem?.asset as? AVURLAsset else { return }
        let plain: URL?
        switch asset.url.scheme {
        case scheme:                  plain = unwrap(asset.url)
        case LivePlaylistLoader.scheme: plain = LivePlaylistLoader.unwrap(asset.url)
        default:                      plain = nil
        }
        guard let plain else { return }
        logger.info("UNMUTE", "AirPlay : retour à la playlist d'origine", nil)
        let t = player.currentTime()
        let item = AVPlayerItem(url: plain)
        SpatialAudio.apply(to: item)
        keepPitch(item)
        AdBreakMonitor.attach(to: item)
        var obs: NSKeyValueObservation?
        obs = item.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                obs?.invalidate(); obs = nil
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    // MARK: Chargement
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme,
              let real = Self.unwrap(url) else { return false }
        Task {
            if let data = await self.playlist(real) {
                loadingRequest.dataRequest?.respond(with: data)
                loadingRequest.finishLoading()
            } else {
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
            }
        }
        return true
    }

    private func cached(_ key: String) -> (data: Data, outcome: Outcome?)? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    private func store(_ data: Data, outcome: Outcome?, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if cache.count > 20 { cache.removeAll() }
        cache[key] = (data, outcome)
    }

    private func playlist(_ url: URL) async -> Data? {
        // Playlist déjà réécrite : on refait l'annonce. Le lecteur remet la
        // barre aux passages coupés de GQL à chaque ouverture : sans elle, une
        // VOD rouverte montrerait muets des passages qui ont le son.
        if let hit = cached(url.absoluteString) {
            if let outcome = hit.outcome { await announce(outcome, for: url.absoluteString) }
            return hit.data
        }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("#EXTM3U") else { return nil }
        let (rewritten, outcome) = await rewrite(text, base: url)
        let out = Data(rewritten.utf8)
        store(out, outcome: outcome, for: url.absoluteString)
        if let outcome { await announce(outcome, for: url.absoluteString) }
        return out
    }

    /// Adresses rendues absolues (la base n'est plus celle du CDN), passages
    /// coupés remplacés par leur original quand le CDN l'a encore.
    /// Avec l'annonce à faire (nil : rien de coupé).
    private func rewrite(_ text: String, base: URL) async -> (String, Outcome?) {
        var lines = text.components(separatedBy: "\n")
        struct Muted { let index: Int; let original: URL; let start: Double; let duration: Double }
        var muted: [Muted] = []
        // Passages coupés déjà servis avec le son (« -unmuted.mp4 »).
        var kept = 0
        var clock = 0.0, pending = 0.0
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                pending = Double(line.dropFirst(8).split(separator: ",").first ?? "") ?? 0
                continue
            }
            if line.hasPrefix("#") {
                // Segment d'initialisation des VODs en fMP4 : il passait par ce
                // chargeur, qui ne sert que des playlists — image noire.
                if let fixed = absoluteURIAttribute(line, base: base) { lines[i] = fixed }
                continue
            }
            guard !line.isEmpty, let abs = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            var segment = abs.absoluteString
            // « N-unmuted.mp4 » (VODs en fMP4) : le CDN le sert, AVEC le son
            // (sondé : piste audio pleine, « N-muted.mp4 » est silencieux et
            // « N.mp4 » refusé). Surtout pas de version muette : on le garde.
            if segment.contains("-unmuted.mp4") {
                kept += 1
                lines[i] = segment
                clock += pending
                pending = 0
                continue
            }
            // « N-muted.ts » / « N-unmuted.ts », ou « N-muted.mp4 » en fMP4.
            if let r = segment.range(of: #"-(un)?muted\.(ts|mp4)"#, options: .regularExpression) {
                let ext = segment[r].hasSuffix(".mp4") ? "mp4" : "ts"
                // « -unmuted.ts » est refusé par le CDN : la version muette sert de repli.
                let original = segment.replacingCharacters(in: r, with: ".\(ext)")
                segment = segment.replacingCharacters(in: r, with: "-muted.\(ext)")
                if let o = URL(string: original) {
                    muted.append(Muted(index: i, original: o, start: clock, duration: pending))
                }
            }
            lines[i] = segment
            clock += pending
            pending = 0
        }
        // Rien de coupé : pas d'annonce. Que des « -unmuted.mp4 » : annonce
        // quand même, la barre ne doit plus montrer ces passages comme muets
        // (`exist([])` rend [] sans requête).
        guard !muted.isEmpty || kept > 0 else { return (lines.joined(separator: "\n"), nil) }

        // Quatre premiers d'abord : tous refusés, les originaux sont effacés
        // (VOD trop ancienne) — inutile d'interroger les centaines suivants.
        var available = Set<Int>()
        let probe = Array(muted.prefix(4))
        let first = await exist(probe.map(\.original))
        for (k, ok) in first.enumerated() where ok { available.insert(probe[k].index) }
        if !available.isEmpty, muted.count > probe.count {
            let rest = Array(muted.dropFirst(probe.count))
            let others = await exist(rest.map(\.original))
            for (k, ok) in others.enumerated() where ok { available.insert(rest[k].index) }
        }
        for m in muted where available.contains(m.index) { lines[m.index] = m.original.absoluteString }

        // Passages encore muets, fusionnés, pour la barre de lecture.
        var remaining: [MutedRange] = []
        for m in muted where !available.contains(m.index) {
            if let last = remaining.last, m.start <= last.end + 0.5 {
                remaining[remaining.count - 1] = MutedRange(start: last.start, end: m.start + m.duration)
            } else {
                remaining.append(MutedRange(start: m.start, end: m.start + m.duration))
            }
        }
        logger.info("UNMUTE", "Passages coupés : \(available.count)/\(muted.count) segments rétablis, \(kept) déjà avec le son (-unmuted.mp4)",
                    base.deletingLastPathComponent().lastPathComponent)
        // Les « -unmuted.mp4 » comptent comme rétablis : ils se lisent avec le son.
        let outcome = Outcome(restored: available.count + kept, remaining: remaining)
        return (lines.joined(separator: "\n"), outcome)
    }

    /// `resultNotification` pour la playlist `url` (adresse du CDN).
    private func announce(_ outcome: Outcome, for url: String) async {
        await MainActor.run {
            NotificationCenter.default.post(name: Self.resultNotification, object: nil, userInfo: [
                "url": url, "restored": outcome.restored, "remaining": outcome.remaining,
            ])
        }
    }

    /// Le CDN sert-il ces fichiers ? HEAD en parallèle, huit à la fois.
    private func exist(_ urls: [URL]) async -> [Bool] {
        var result = [Bool](repeating: false, count: urls.count)
        await withTaskGroup(of: (Int, Bool).self) { group in
            var next = 0
            while next < min(8, urls.count) {
                let i = next; next += 1
                group.addTask { let ok = await VodUnmuteLoader.head(urls[i]); return (i, ok) }
            }
            while let done = await group.next() {
                result[done.0] = done.1
                if next < urls.count {
                    let j = next; next += 1
                    group.addTask { let ok = await VodUnmuteLoader.head(urls[j]); return (j, ok) }
                }
            }
        }
        return result
    }

    private static func head(_ url: URL) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "HEAD"
        let code = (try? await URLSession.shared.data(for: req).1 as? HTTPURLResponse)?.statusCode
        return code == 200
    }
}

/// Balise avec une adresse relative (`#EXT-X-MAP:URI="init-0.mp4"`) : adresse
/// rendue absolue. Une playlist servie par un chargeur maison (`tuunmute://`,
/// `tulive://`) n'a plus le CDN pour base : AVPlayer demanderait le fichier
/// au chargeur. nil : rien à changer.
func absoluteURIAttribute(_ line: String, base: URL) -> String? {
    // L'attribut URI lui-même (pas « …-URL » d'une autre balise).
    guard let r = line.range(of: #"(?<=[:,])URI="[^"]+""#, options: .regularExpression) else { return nil }
    let value = String(line[r].dropFirst(5).dropLast())
    guard let abs = URL(string: value, relativeTo: base)?.absoluteURL.absoluteString, abs != value else { return nil }
    return line.replacingCharacters(in: r, with: "URI=\"\(abs)\"")
}
