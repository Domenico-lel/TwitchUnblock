import SwiftUI
import AVKit
import AVFoundation

// État plein écran partagé : permet à ChatView de ne pas couper l'IRC/les points
// quand le lecteur passe en plein écran (ce qui déclenche un onDisappear transitoire).
enum PlayerFullscreen {
    static var isActive = false
}

// MARK: – AVPlayerViewController wrapper
struct NativeVideoPlayer: UIViewControllerRepresentable {
    let url: URL
    let savedTime: Double
    let onProgress: (Double) -> Void
    /// Latence mesurée du direct (nil si la playlist ne porte pas d'horodatage).
    var onLatency: (Double?) -> Void = { _ in }
    /// Distance au bord du direct, en secondes (nil hors direct).
    var onBehind: (Double?) -> Void = { _ in }
    /// Mode faible latence : ne s'applique qu'au direct.
    var lowLatency: Bool = false
    var isLive: Bool = false
    /// Titre, chaîne et image affichés sur l'écran verrouillé.
    var nowPlaying = NowPlayingMeta()

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let player = AVPlayer(playerItem: VodUnmuteLoader.playerItem(url: url))
        // Le son continue écran verrouillé, comme dans le lecteur immersif.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.showsPlaybackControls = true
        vc.delegate = context.coordinator
        context.coordinator.playerVC = vc
        context.coordinator.isLive = isLive
        context.coordinator.lowLatency = lowLatency && isLive
        context.coordinator.configureLatency(player)
        context.coordinator.setupObserver(player: player, onProgress: onProgress,
                                          onLatency: onLatency, onBehind: onBehind)
        context.coordinator.applyMetadata(nowPlaying, isLive: isLive, to: player)
        // Restore position
        if savedTime > 5 {
            player.seek(to: CMTime(seconds: savedTime, preferredTimescale: 600))
        }
        player.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        let currentURL = (vc.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url {
            // ✨ LA CORRECTION EST ICI : On force l'ancien lecteur à se mettre en pause 
            // avant de le remplacer par la nouvelle qualité !
            vc.player?.pause()
            
            let player = AVPlayer(playerItem: VodUnmuteLoader.playerItem(url: url))
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
            vc.player = player
            context.coordinator.isLive = isLive
            context.coordinator.lowLatency = lowLatency && isLive
            context.coordinator.configureLatency(player)
            context.coordinator.setupObserver(player: player, onProgress: onProgress,
                                              onLatency: onLatency, onBehind: onBehind)
            if savedTime > 5 {
                player.seek(to: CMTime(seconds: savedTime, preferredTimescale: 600))
            }
            player.play()
        }
        if let player = vc.player { context.coordinator.applyMetadata(nowPlaying, isLive: isLive, to: player) }
    }

    // Force l'arrêt de la vidéo quand la vue est détruite
    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        vc.player?.pause()
        vc.player = nil
        PlayerActivity.end()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        weak var playerVC: AVPlayerViewController?
        private var timeObserver: Any?
        private var playerRef: AVPlayer?
        private var externalObs: NSKeyValueObservation?

        /// Lecture d'un direct (journaux LIVE).
        var isLive = false
        /// Mode faible latence actif (direct uniquement).
        var lowLatency = false
        private var lastCatchUp = Date.distantPast
        private var latency = LiveLatencyController()
        private var sync = LiveSyncEstimator()
        private var diagnostics: LiveDiagnostics?
        private var jumpObserver: NSObjectProtocol?


        /// Prépare le direct : le mode faible latence tient ensuite le bord du
        /// direct en continu (catchUpIfNeeded).
        ///
        /// Ne jamais remettre `automaticallyWaitsToMinimizeStalling = false` ni un
        /// `configuredTimeOffsetFromLive` inférieur à `recommendedTimeOffsetFromLive` :
        /// le lecteur démarre alors sans tampon et passe son temps à se recharger.
        func configureLatency(_ player: AVPlayer) {
            // Le Coordinator survit au changement de qualité (nouvel AVPlayer) :
            // la tenue du direct repart de zéro, recalage du démarrage compris.
            latency.reset()
            guard lowLatency else { return }
            lastCatchUp = Date()   // laisse le flux démarrer avant tout rattrapage
            logger.info("LIVE", "Mode faible latence actif", "tenue du bord du direct (sauts seulement, vitesse ×1)")
        }

        /// Tient le bord du direct par des sauts seulement : voir
        /// LiveLatencyController. En pause, on ne touche à rien.
        private func catchUpIfNeeded() {
            guard lowLatency, let player = playerRef, let item = player.currentItem,
                  let liveEdge = item.seekableTimeRanges.last?.timeRangeValue.end,
                  liveEdge.isValid, liveEdge.isNumeric else { return }
            let behind = (liveEdge - item.currentTime()).seconds
            // Le recalage du démarrage part dès que la lecture a commencé ; le
            // reste laisse d'abord le flux démarrer (quelques secondes).
            latency.adjust(player: player, item: item, behind: behind,
                           total: item.currentDate().map { Date().timeIntervalSince($0) },
                           enabled: player.rate > 0 && behind > 0,
                           settled: Date().timeIntervalSince(lastCatchUp) > 4)
        }

        /// Les commandes d'AVPlayerViewController (−15 s, barre) ne passent pas
        /// par notre code : un saut loin du bord est un recul voulu, que la
        /// tenue du direct ne doit pas défaire. Les sauts du contrôleur, eux,
        /// sont écartés par leur horodatage (marge pour une recherche lente),
        /// comme ceux du démarrage (position initiale, recalage).
        private func timeJumped(_ item: AVPlayerItem) {
            guard lowLatency, item === playerRef?.currentItem, latency.aligned,
                  Date().timeIntervalSince(lastCatchUp) > 4,
                  Date().timeIntervalSince(latency.lastJumpAt) > 5,
                  let edge = item.seekableTimeRanges.last?.timeRangeValue.end, edge.isNumeric else { return }
            let behind = (edge - item.currentTime()).seconds
            guard behind.isFinite else { return }
            latency.hold(behind > latency.minBehind(for: item) + 3)
        }

        // MARK: Plein écran — maintient PlayerFullscreen.isActive à jour
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            PlayerFullscreen.isActive = true
        }
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            coordinator.animate(alongsideTransition: nil) { _ in
                PlayerFullscreen.isActive = false
            }
        }

        /// Jeton de l'observateur à bloc : `removeObserver(self)` ne le retire
        /// pas, il restait un observateur par lecteur ouvert.
        private var stopObserver: NSObjectProtocol?
        private var spatialObserver: NSObjectProtocol?

        override init() {
            super.init()
            spatialObserver = NotificationCenter.default.addObserver(
                forName: .tuSpatialAudioChanged, object: nil, queue: .main
            ) { [weak self] _ in self?.reloadForSpatialAudio() }
            // Coupe instantanément le son si on reçoit le signal "ForceStopVideo" depuis la croix
            stopObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("ForceStopVideo"), object: nil, queue: .main) { [weak self] _ in
                self?.playerVC?.player?.pause()
                self?.playerVC?.player = nil
            }
        }

        /// Réglage « Audio spatial » changé : l'élément est recréé au même
        /// endroit (rien ne garantit qu'iOS relise ce choix en cours de lecture).
        private func reloadForSpatialAudio() {
            guard let player = playerRef,
                  let current = player.currentItem,
                  let asset = current.asset as? AVURLAsset else { return }
            let live = current.duration.isIndefinite
            let t = player.currentTime()
            let playing = player.rate > 0
            let item = VodUnmuteLoader.playerItem(url: asset.url)
            if !live {
                // Chercher avant que la playlist soit chargée ne tient pas.
                var obs: NSKeyValueObservation?
                obs = item.observe(\.status, options: [.new]) { item, _ in
                    guard item.status == .readyToPlay else { return }
                    DispatchQueue.main.async {
                        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                        obs?.invalidate(); obs = nil
                    }
                }
            } else {
                // Nouvel élément du direct : la tenue repart de zéro.
                latency.reset()
                lastCatchUp = Date()
            }
            player.replaceCurrentItem(with: item)
            if playing { player.play() }
        }

        func setupObserver(player: AVPlayer,
                           onProgress: @escaping (Double) -> Void,
                           onLatency: @escaping (Double?) -> Void = { _ in },
                           onBehind: @escaping (Double?) -> Void = { _ in }) {
            if let existing = timeObserver { playerRef?.removeTimeObserver(existing) }
            playerRef = player
            sync.reset()
            // Journaux LIVE et sauts du lecteur : réabonnés à chaque nouvel
            // AVPlayer (changement de qualité).
            diagnostics = LiveDiagnostics(player: player) { [weak self] in self?.isLive ?? false }
            if isLive { LiveDiagnostics.logAudioRoute("début du direct") }
            if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
            jumpObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let item = note.object as? AVPlayerItem else { return }
                self?.timeJumped(item)
            }
            // AirPlay ne lit pas les playlists réécrites : retour à celle du CDN.
            externalObs = player.observe(\.isExternalPlaybackActive, options: [.new]) { p, _ in
                DispatchQueue.main.async { VodUnmuteLoader.fallBackForAirPlay(p) }
            }
            // 1 s : assez fin pour synchroniser le chat des VODs.
            let interval = CMTime(seconds: 1, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
                onProgress(time.seconds)
                // Latence = écart entre l'heure réelle et l'horodatage du segment lu
                // (EXT-X-PROGRAM-DATE-TIME de la playlist HLS). nil si absent.
                let total = player?.currentItem?.currentDate().map { Date().timeIntervalSince($0) }
                onLatency(total)
                // Retard sur le direct tel que le voient les autres spectateurs :
                // la base de la synchro du chat (LiveSyncEstimator). Un direct
                // n'a pas de durée finie.
                if let self, let item = player?.currentItem, item.duration.isIndefinite,
                   let edge = item.seekableTimeRanges.last?.timeRangeValue.end, edge.isNumeric {
                    onBehind(self.sync.offset(latency: total,
                                              behind: (edge - item.currentTime()).seconds))
                } else {
                    onBehind(nil)
                }
                if let self, self.isLive, let item = player?.currentItem {
                    self.diagnostics?.tick(item: item)
                }
                self?.catchUpIfNeeded()
            }
        }

        // MARK: Écran verrouillé
        // AVPlayerViewController publie lui-même la lecture et ses commandes sur
        // l'écran verrouillé ; il lui manquait seulement le titre, la chaîne et
        // l'image, qu'il lit dans les métadonnées de l'élément lu.
        private var metadataShown: NowPlayingMeta?
        private weak var metadataItem: AVPlayerItem?
        private var artworkData: Data?
        private var artworkTask: Task<Void, Never>?

        func applyMetadata(_ meta: NowPlayingMeta, isLive: Bool, to player: AVPlayer) {
            guard let item = player.currentItem,
                  meta != metadataShown || item !== metadataItem else { return }
            // Live Activity : ce lecteur ne suit pas la pause, elle reste en lecture.
            PlayerActivity.update(meta, isLive: isLive, isPlaying: true)
            if meta.artworkURL != metadataShown?.artworkURL {
                artworkData = nil
                artworkTask?.cancel()
                if let address = meta.artworkURL, let url = URL(string: address) {
                    artworkTask = Task { [weak self, weak player] in
                        guard let (data, _) = try? await URLSession.shared.data(from: url),
                              !Task.isCancelled else { return }
                        await MainActor.run {
                            guard let self, let item = player?.currentItem else { return }
                            self.artworkData = data
                            self.writeMetadata(meta, to: item)
                        }
                    }
                }
            }
            metadataShown = meta
            metadataItem = item
            writeMetadata(meta, to: item)
        }

        private func writeMetadata(_ meta: NowPlayingMeta, to item: AVPlayerItem) {
            func entry(_ identifier: AVMetadataIdentifier,
                       _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
                let m = AVMutableMetadataItem()
                m.identifier = identifier
                m.value = value
                m.extendedLanguageTag = "und"
                return m
            }
            var items = [entry(.commonIdentifierTitle, meta.title as NSString),
                         entry(.commonIdentifierArtist, meta.artist as NSString)]
            if let artworkData {
                items.append(entry(.commonIdentifierArtwork, artworkData as NSData))
            }
            item.externalMetadata = items
        }

        deinit {
            if let obs = timeObserver { playerRef?.removeTimeObserver(obs) }
            if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
            if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
            artworkTask?.cancel()
        }
    }
}

// MARK: – Full Video Player View
struct VideoPlayerView: View {
    let qualityLinks: QualityLinks
    /// VOD à reprendre et dont on garde la progression (nil sinon).
    let vodId: String?
    /// Direct en cours, donné par l'appelant : faux pendant son rembobinage,
    /// et pour un clip ou une VOD retrouvée ou téléchargée, qui n'ont pas
    /// d'identifiant de VOD mais ne sont pas des directs. Décide de la tenue
    /// du direct, de la latence et de la synchro du chat.
    let isLive: Bool
    /// Mode compact (chat ouvert) : masque la barre Source / le lien pour laisser
    /// un maximum de place au chat. Seul le lecteur reste visible.
    var compact: Bool = false
    /// Titre, chaîne et image affichés sur l'écran verrouillé.
    var nowPlaying = NowPlayingMeta()
    /// Position de lecture remontee au parent (utilisee par le chat des VODs).
    var onTime: (Double) -> Void = { _ in }
    /// Latence du direct remontee au parent (affichage).
    var onLatency: (Double?) -> Void = { _ in }
    /// Distance au bord du direct remontee au parent (synchro auto du chat).
    var onBehind: (Double?) -> Void = { _ in }
    // Actions affichees a cote du bouton Source (nil = bouton masque).
    var onChat: (() -> Void)? = nil
    var onRewind: (() -> Void)? = nil
    var onBackToLive: (() -> Void)? = nil

    @EnvironmentObject private var store: AppStore
    @State private var selectedQuality: String = ""
    @State private var showQualityPicker = false
    @State private var currentTime: Double = 0
    @State private var lastPersisted: Double = -99
    @State private var latency: Double? = nil

    private var qualities: [String] { sortQualities(Array(qualityLinks.keys)) }
    private var currentURL: URL? { qualityLinks[selectedQuality].flatMap(URL.init) }

    var body: some View {
        VStack(spacing: 0) {

            // ── Player ──────────────────────────────────────────────
            if let url = currentURL {
                nativePlayer(url: url)
            }

            // En mode compact (chat ouvert) on n'affiche que le lecteur.
            if !compact {
            // ── Options bar ─────────────────────────────────────────
            // Tous les boutons partagent la même hauteur fixe : sinon une icône
            // SF Symbol (taille « body » par défaut) rend son bouton plus haut
            // que celui qui ne contient que du texte en 12 pt.
            HStack(spacing: 8) {
                // Qualité : bouton compact, il laisse la place aux actions.
                Button { showQualityPicker.toggle() } label: {
                    actionLabel(text: qualityLabel(selectedQuality), emoji: "🎬",
                                fg: .white, bg: Color.tPrimary)
                }

                if let rewind = onRewind {
                    Button(action: rewind) {
                        actionLabel(text: store.t("rewind"), icon: "gobackward",
                                    fg: .tPrimary, bg: Color.tPrimary.opacity(0.15),
                                    border: .tPrimary)
                    }
                }

                if let backLive = onBackToLive {
                    Button(action: backLive) {
                        actionLabel(text: store.t("back_to_live"), dot: true,
                                    fg: .white, bg: Color.tLive)
                    }
                }

                Spacer(minLength: 0)

                if let chat = onChat {
                    Button(action: chat) {
                        actionLabel(text: "Chat", icon: "bubble.left.fill",
                                    fg: .white, bg: Color.tPrimary)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(Color.tCard)

            // ── Quality picker ──────────────────────────────────────
            if showQualityPicker {
                VStack(spacing: 0) {
                    ForEach(qualities, id: \.self) { q in
                        Button {
                            currentTime = 0
                            selectedQuality = q
                            store.rememberQualityChoice(q)
                            showQualityPicker = false
                        } label: {
                            HStack {
                                Text(q == selectedQuality ? "✓  " : "    ")
                                    .foregroundColor(q == selectedQuality ? .tPrimary : .clear)
                                Text(qualityLabel(q))
                                    .foregroundColor(q == selectedQuality ? .tPrimary : .tMuted)
                                    .fontWeight(q == selectedQuality ? .bold : .semibold)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        Divider().background(Color.tBorder)
                    }
                }
                .background(Color.tSurface)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.tBorder, lineWidth: 1))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            } // fin if !compact
        }
        .background(Color.tCard)
        .cornerRadius(16)
        .onAppear {
            if selectedQuality.isEmpty {
                selectedQuality = store.preferAudioOnly && qualities.contains("audio_only")
                    ? "audio_only" : (qualities.first ?? "")
            }
        }
    }

    // Lecteur natif (AVPlayerViewController) avec PiP + reprise de position.
    @ViewBuilder
    private func nativePlayer(url: URL) -> some View {
        NativeVideoPlayer(
            url: url,
            savedTime: vodId.map { store.getVodProgress($0) } ?? 0,
            onProgress: { time in
                currentTime = time
                onTime(time)
                // Progression persistee au plus toutes les 5 s (l'observateur tourne a 1 s,
                // inutile d'ecrire dans UserDefaults a chaque tick).
                if let id = vodId, abs(time - lastPersisted) >= 5 {
                    lastPersisted = time
                    store.setVodProgress(id, time: time)
                }
            },
            onLatency: { value in
                // Seul le direct a une latence exploitable.
                let measured = isLive ? value : nil
                if latency != measured { latency = measured }
                onLatency(measured)
            },
            onBehind: { value in onBehind(isLive ? value : nil) },
            lowLatency: store.lowLatency,
            isLive: isLive,
            nowPlaying: nowPlaying
        )
        .aspectRatio(16/9, contentMode: .fit)
        .background(Color.black)
        .overlay(alignment: .topLeading) {
            if store.showLatency, isLive {
                latencyChip.padding(8)
            }
        }
    }

    // MARK: – Débogage : pastille de latence
    @ViewBuilder
    private var latencyChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 9, weight: .bold))
            Text(latency.map { String(format: "%.1f s", max(0, $0)) } ?? "—")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
        }
        .foregroundColor(latencyColor)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .cornerRadius(6)
    }

    /// Vert < 8 s (faible latence), jaune < 20 s, rouge au-delà.
    private var latencyColor: Color {
        guard let l = latency else { return .tMuted }
        if l < 8  { return .tSuccess }
        if l < 20 { return .tWarning }
        return .tDanger
    }

    // MARK: – Bouton de la barre d'actions (hauteur commune)
    @ViewBuilder
    private func actionLabel(text: String, emoji: String? = nil, icon: String? = nil,
                             dot: Bool = false, fg: Color, bg: Color,
                             border: Color? = nil) -> some View {
        HStack(spacing: 4) {
            if let emoji { Text(emoji).font(.system(size: 12)) }
            if let icon  { Image(systemName: icon).font(.system(size: 12, weight: .bold)) }
            if dot       { Circle().fill(fg).frame(width: 6, height: 6) }
            Text(text).font(.system(size: 12, weight: .bold))
        }
        .foregroundColor(fg)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(bg)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1)
        )
    }

    private func qualityLabel(_ q: String) -> String {
        q.replacingOccurrences(of: "chunked", with: "Source")
         .replacingOccurrences(of: "source",  with: "Source")
    }
}
