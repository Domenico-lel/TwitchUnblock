import SwiftUI
import AVKit
import AVFoundation

// ═══════════════════════════════════════════════════════════════════════════
//  Lecteur de l'app Apple TV : le lecteur natif de tvOS (barre de lecture,
//  glissés de la télécommande, panneau d'infos), avec en plus dans sa barre
//  Qualité, Chat (le chat posé sur l'image, direct ou VOD, voir TVChat) et
//  pour un direct Source. Mêmes liens que l'iPhone :
//  sources sans pub pour les lives, passages coupés rétablis sur les VODs
//  récentes quand c'est possible.
// ═══════════════════════════════════════════════════════════════════════════

struct TVPlayerScreen: View {
    let item: TVPlayback
    @EnvironmentObject private var session: TVSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = TVPlayerModel()
    @StateObject private var chat = TVChatModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = model.player {
                TVPlayerController(player: player, model: model, session: session, chat: chat)
                    .ignoresSafeArea()
            } else if let error = model.error {
                VStack(spacing: 40) {
                    Text(error).font(.title3).multilineTextAlignment(.center)
                    Button(session.t("tv_back")) { dismiss() }
                }
                .padding(80)
            } else {
                ProgressView()
            }
        }
        .task {
            switch item {
            case .live(let login, _): chat.start(login)
            case .vod(let id, _):     chat.startVod(id)
            }
            await model.load(item, session: session)
        }
        // VOD : le chat suit la lecture (commentaires rejoués à leur instant).
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard case .vod = item, let time = model.player?.currentTime().seconds else { return }
            chat.update(offset: time)
        }
        .onDisappear {
            model.stop()
            chat.stop()
        }
        .onExitCommand { dismiss() }
    }
}

@MainActor
final class TVPlayerModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var error: String?
    @Published private(set) var links: QualityLinks = [:]
    @Published private(set) var quality = ""
    private(set) var isLive = false

    private var current: TVPlayback?
    private var title = ""
    private var subtitle = ""
    private var vodId: String?
    private var statusObs: NSKeyValueObservation?
    private var timeObs: Any?

    func load(_ item: TVPlayback, session: TVSession) async {
        current = item
        error = nil
        switch item {
        case .live(let login, let name):
            isLive = true
            title = name
            vodId = nil
            let data = await getLive(channelName: login)
            guard let raw = data.links, !raw.isEmpty else {
                error = session.t(data.error == "offline" ? "tv_offline" : "tv_error_live")
                return
            }
            subtitle = data.title
            // Playlists réécrites avec la vraie durée des segments (2 s) : le
            // lecteur tient le bord du direct au lieu de rester ~20 s derrière.
            links = LivePlaylistLoader.wrap(raw)
        case .vod(let id, let videoTitle):
            isLive = false
            title = videoTitle
            subtitle = ""
            vodId = id
            async let markersTask = getVodMarkers(vodId: id)
            let data = await getM3U8(vodId: id)
            let markers = await markersTask
            guard !data.links.isEmpty else {
                error = data.error ?? session.t("tv_error_vod")
                return
            }
            // VOD récente avec des passages coupés : le son d'origine est
            // peut-être encore sur le CDN (VodUnmuteLoader).
            links = VodUnmuteLoader.worthTrying(markers) ? VodUnmuteLoader.wrap(data.links) : data.links
        }
        let keys = sortQualities(Array(links.keys))
        let saved = UserDefaults.standard.string(forKey: "tv_quality") ?? ""
        quality = keys.contains(saved) ? saved
            : (keys.first { $0.lowercased() != "audio_only" } ?? keys.first ?? "")
        start(at: isLive ? 0 : TVProgress.position(vodId))
    }

    /// (Re)lance la qualité choisie, à `seconds` pour une VOD.
    private func start(at seconds: Double) {
        guard let link = links[quality], let url = URL(string: link) else { return }
        let item = VodUnmuteLoader.playerItem(url: url)
        item.externalMetadata = metadata()
        // Chercher avant que la playlist soit chargée ne tient pas.
        statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .readyToPlay, seconds > 5, let model = self else { return }
            Task { @MainActor in
                model.player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                                   toleranceBefore: .zero, toleranceAfter: .zero)
                model.statusObs = nil
            }
        }
        let p = player ?? AVPlayer()
        p.replaceCurrentItem(with: item)
        p.play()
        if player == nil {
            player = p
            // Avancement d'une VOD gardé toutes les 10 s (reprise au même endroit).
            if let id = vodId {
                timeObs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1),
                                                    queue: .main) { [weak p] time in
                    let duration = p?.currentItem?.duration.seconds ?? 0
                    TVProgress.save(id, at: time.seconds, duration: duration.isFinite ? duration : 0)
                }
            }
        }
    }

    func setQuality(_ key: String) {
        guard key != quality, links[key] != nil else { return }
        quality = key
        UserDefaults.standard.set(key, forKey: "tv_quality")
        start(at: isLive ? 0 : (player?.currentTime().seconds ?? 0))
    }

    /// Source du direct changée : liens redemandés à la nouvelle source.
    func reload(session: TVSession) async {
        guard let current else { return }
        await load(current, session: session)
    }

    func stop() {
        if let p = player, let id = vodId {
            let duration = p.currentItem?.duration.seconds ?? 0
            TVProgress.save(id, at: p.currentTime().seconds, duration: duration.isFinite ? duration : 0)
        }
        if let o = timeObs { player?.removeTimeObserver(o) }
        timeObs = nil
        statusObs = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
    }

    /// Titre et sous-titre du panneau d'infos de tvOS.
    private func metadata() -> [AVMetadataItem] {
        func entry(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = identifier
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        var out = [entry(.commonIdentifierTitle, title)]
        if !subtitle.isEmpty { out.append(entry(.iTunesMetadataTrackSubTitle, subtitle)) }
        return out
    }
}

@MainActor
struct TVPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    @ObservedObject var model: TVPlayerModel
    @ObservedObject var session: TVSession
    let chat: TVChatModel

    final class Coordinator {
        var chatHost: UIHostingController<TVChatOverlay>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.transportBarCustomMenuItems = menus()
        // Chat dans le calque du lecteur : sur l'image, sous les commandes,
        // sans jamais prendre le focus.
        let host = UIHostingController(rootView: TVChatOverlay(
            model: chat, waitingText: session.t(model.isLive ? "tv_chat_waiting" : "tv_chat_loading")))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        if let overlay = vc.contentOverlayView {
            vc.addChild(host)
            host.view.frame = overlay.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.addSubview(host.view)
            host.didMove(toParent: vc)
        }
        context.coordinator.chatHost = host
        showChat(context)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
        vc.transportBarCustomMenuItems = menus()
        showChat(context)
    }

    private func showChat(_ context: Context) {
        context.coordinator.chatHost?.view.isHidden = !session.tvChat
    }

    /// Menus de la barre de lecture : Qualité, et Source pour un direct.
    private func menus() -> [UIMenuElement] {
        let model = self.model
        let session = self.session
        let qualities: [UIMenuElement] = sortQualities(Array(model.links.keys)).map { key in
            UIAction(title: label(key), state: key == model.quality ? .on : .off) { _ in
                Task { @MainActor in model.setQuality(key) }
            }
        }
        var items: [UIMenuElement] = [
            UIMenu(title: session.t("quality"), image: UIImage(systemName: "slider.horizontal.3"),
                   children: qualities)
        ]
        if model.isLive {
            let sources: [UIMenuElement] = kLiveSourceChoices.map { id in
                UIAction(title: session.t("src_\(id)"), state: id == session.liveSource ? .on : .off) { _ in
                    Task { @MainActor in
                        session.liveSource = id
                        await model.reload(session: session)
                    }
                }
            }
            items.append(UIMenu(title: session.t("live_source"),
                                image: UIImage(systemName: "antenna.radiowaves.left.and.right"),
                                children: sources))
        }
        // Chat affiché ou masqué (gardé pour les prochaines lectures).
        items.append(UIAction(title: session.t("tv_chat"),
                              image: UIImage(systemName: session.tvChat ? "bubble.left.and.bubble.right.fill"
                                                                        : "bubble.left.and.bubble.right"),
                              state: session.tvChat ? .on : .off) { _ in
            Task { @MainActor in session.tvChat.toggle() }
        })
        return items
    }

    private func label(_ key: String) -> String {
        switch key.lowercased() {
        case "chunked", "source": return "Source"
        case "audio_only":        return session.t("tv_audio")
        default:                  return key
        }
    }
}
