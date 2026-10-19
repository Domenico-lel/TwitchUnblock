import SwiftUI
import AVFoundation

// ═══════════════════════════════════════════════════════════════════════════
//  Onglet Découvrir : un live (ou un clip) par écran, qu'on fait défiler
//  vers le haut, comme le fil de l'app Twitch. La page affichée joue un
//  aperçu muet en petite qualité ; un toucher ouvre le lecteur complet
//  (son, chat). Masquable dans les Réglages (AppStore.showDiscoverTab).
// ═══════════════════════════════════════════════════════════════════════════

// MARK: – Données et aperçus
@MainActor
final class DiscoverFeed: ObservableObject {
    enum Preview: Equatable { case loading, ready, failed }

    @Published private(set) var lives: [TwitchStream] = []
    @Published private(set) var clips: [FeedClip] = []
    @Published private(set) var livesLoaded = false
    @Published private(set) var livesFailed = false
    @Published private(set) var clipsLoaded = false
    @Published private(set) var clipsFailed = false
    /// État de l'aperçu, par page (« live:<login> », « clip:<slug> »).
    @Published private(set) var preview: [String: Preview] = [:]
    /// Photo des chaînes, connue une fois leur live résolu.
    @Published private(set) var avatars: [String: String] = [:]
    /// Page dont l'aperçu joue (nil : aucune).
    @Published private(set) var playing: String?

    /// Un seul lecteur pour tout le fil, toujours muet.
    let player: AVPlayer = {
        let p = AVPlayer()
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        return p
    }()

    private var lang: String?
    private var next: String?
    private var loadingMore = false
    /// Adresses déjà trouvées (5 min) : revenir sur une page ne relance pas
    /// toutes les sources du direct.
    private var resolved: [String: (url: URL, at: Date)] = [:]
    private var resolveTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var ambient = false

    // MARK: Lives du top
    /// Top dans la langue du top, sans les chaînes et catégories masquées.
    func loadLives(lang: String?, keep: (TwitchStream) -> Bool) async {
        self.lang = lang
        livesFailed = false
        guard let page = await getTopStreamsPageGQL(lang: lang, after: nil) else {
            livesFailed = lives.isEmpty
            livesLoaded = true
            return
        }
        lives = unique(page.streams.filter(keep))
        next = page.refused ? nil : page.next
        livesLoaded = true
        // Les clips suivent les chaînes du moment : relus au besoin.
        clips = []
        clipsLoaded = false
    }

    /// Près de la fin : la page suivante du top.
    func loadMoreLives(after index: Int, keep: (TwitchStream) -> Bool) async {
        guard index >= lives.count - 5, let after = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = await getTopStreamsPageGQL(lang: lang, after: after) else { return }
        let known = Set(lives.map { $0.userLogin.lowercased() })
        lives += unique(page.streams.filter { keep($0) && !known.contains($0.userLogin.lowercased()) })
        next = page.refused ? nil : page.next
    }

    private func unique(_ list: [TwitchStream]) -> [TwitchStream] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.userLogin.lowercased()).inserted }
    }

    // MARK: Clips du moment
    /// Clips les plus vus des dernières 24 h des chaînes du top.
    func loadClips() async {
        guard !clipsLoaded else { return }
        let logins = lives.prefix(20).map { $0.userLogin }
        guard !logins.isEmpty else { return }
        clipsFailed = false
        guard let list = await getTopClipsGQL(logins: Array(logins)) else {
            clipsFailed = true
            clipsLoaded = true
            return
        }
        clips = list
        clipsLoaded = true
    }

    // MARK: Aperçus
    /// Aperçu d'un live : ses sources habituelles, en 360p (160p en données
    /// mobiles).
    func show(live s: TwitchStream) {
        let login = s.userLogin.lowercased()
        start("live:" + login, loop: false, avatarFor: login) {
            let data = await getLive(channelName: login)
            guard let links = data.links, !links.isEmpty else { return (nil, data.avatar) }
            let pref = NetworkStatus.shared.isCellular ? "160" : "360"
            let key = preferredQualityKey(Array(links.keys), pref: pref, variants: data.variants)
            return (links[key].flatMap { URL(string: $0) }, data.avatar)
        }
    }

    /// Aperçu d'un clip, en boucle.
    func show(clip c: FeedClip) {
        start("clip:" + c.id, loop: true, avatarFor: nil) {
            guard let clip = await getClip(slug: c.id) else { return (nil, nil) }
            let key = preferredQualityKey(Array(clip.links.keys), pref: "360")
            return (clip.links[key].flatMap { URL(string: $0) }, nil)
        }
    }

    private func start(_ key: String, loop: Bool, avatarFor login: String?,
                       resolve: @escaping () async -> (URL?, String?)) {
        guard playing != key else {
            if player.timeControlStatus == .paused, player.currentItem != nil { player.play() }
            return
        }
        resolveTask?.cancel()
        playing = key
        setAmbient(true)
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let r = resolved[key], Date().timeIntervalSince(r.at) < 300 {
            attach(r.url, key: key, loop: loop)
            return
        }
        preview[key] = .loading
        resolveTask = Task { [weak self] in
            let (url, avatar) = await resolve()
            guard let self, !Task.isCancelled else { return }
            if let login, let avatar { self.avatars[login] = avatar }
            guard self.playing == key else { return }
            guard let url else {
                self.preview[key] = .failed
                return
            }
            self.resolved[key] = (url, Date())
            self.attach(url, key: key, loop: loop)
        }
    }

    private func attach(_ url: URL, key: String, loop: Bool) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 2
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
        if loop {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.player.seek(to: .zero)
                    self?.player.play()
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        preview[key] = .ready
    }

    /// Plus rien ne joue (onglet quitté, lecteur ouvert, app en arrière-plan).
    func stop() {
        resolveTask?.cancel()
        resolveTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        playing = nil
        setAmbient(false)
    }

    /// Aperçus muets : la musique d'une autre app continue (« ambient »). La
    /// catégorie du lecteur est rendue dès qu'ils s'arrêtent, avant qu'un
    /// lecteur ne s'ouvre.
    private func setAmbient(_ on: Bool) {
        guard on != ambient else { return }
        ambient = on
        if on {
            try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        } else {
            PlaybackAudio.configure()
        }
    }
}

// MARK: – Écran
struct DiscoverView: View {
    /// Onglet affiché et aucun lecteur ouvert : les aperçus peuvent jouer.
    let active: Bool
    let onPlayLive: (String) -> Void
    let onPlayClip: (String, String?) -> Void
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var feed = DiscoverFeed()
    @State private var mode = Mode.live
    @State private var liveIndex = 0
    @State private var clipIndex = 0

    enum Mode: Hashable { case live, clips }

    private var canPlay: Bool { active && scenePhase == .active }
    private var lang: String { TopLanguage.resolved(store.topLang) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            GeometryReader { geo in
                if mode == .live { livePages(geo.size) } else { clipPages(geo.size) }
            }
            picker.padding(.top, 10)
        }
        .clipped()
        .task(id: lang) {
            feed.stop()
            await feed.loadLives(lang: lang, keep: store.showsStream)
            liveIndex = 0
            clipIndex = 0
            if mode == .clips { await feed.loadClips() }
            refresh()
        }
        .onChange(of: mode) { m in
            Task {
                if m == .clips { await feed.loadClips() }
                refresh()
            }
        }
        .onChange(of: liveIndex) { i in
            refresh()
            Task { await feed.loadMoreLives(after: i, keep: store.showsStream) }
        }
        .onChange(of: clipIndex) { _ in refresh() }
        .onChange(of: canPlay) { _ in refresh() }
        .onDisappear { feed.stop() }
    }

    /// L'aperçu de la page affichée, ou rien si le fil n'est pas à l'écran.
    private func refresh() {
        guard canPlay else { feed.stop(); return }
        switch mode {
        case .live:
            if feed.lives.indices.contains(liveIndex) { feed.show(live: feed.lives[liveIndex]) } else { feed.stop() }
        case .clips:
            if feed.clips.indices.contains(clipIndex) { feed.show(clip: feed.clips[clipIndex]) } else { feed.stop() }
        }
    }

    // MARK: Pages
    @ViewBuilder
    private func livePages(_ size: CGSize) -> some View {
        if feed.lives.isEmpty {
            status(loaded: feed.livesLoaded, failed: feed.livesFailed) {
                Task {
                    await feed.loadLives(lang: lang, keep: store.showsStream)
                    refresh()
                }
            }
        } else {
            VerticalPager(count: feed.lives.count, index: $liveIndex, size: size) { i in
                DiscoverLivePage(stream: feed.lives[i], isCurrent: i == liveIndex, feed: feed) {
                    let login = feed.lives[i].userLogin
                    feed.stop()
                    onPlayLive(login)
                }
            }
        }
    }

    @ViewBuilder
    private func clipPages(_ size: CGSize) -> some View {
        if feed.clips.isEmpty {
            status(loaded: feed.clipsLoaded, failed: feed.clipsFailed) {
                Task {
                    await feed.loadClips()
                    refresh()
                }
            }
        } else {
            VerticalPager(count: feed.clips.count, index: $clipIndex, size: size) { i in
                DiscoverClipPage(clip: feed.clips[i], isCurrent: i == clipIndex, feed: feed) {
                    let c = feed.clips[i]
                    feed.stop()
                    onPlayClip(c.id, c.title)
                }
            }
        }
    }

    /// Chargement, échec (avec Réessayer) ou fil vide.
    private func status(loaded: Bool, failed: Bool, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            if !loaded {
                ProgressView().tint(.white)
            } else {
                Text(store.t(failed ? "err_network" : "discover_empty"))
                    .font(.system(size: 15)).foregroundColor(.tMuted)
                    .multilineTextAlignment(.center)
                Button(store.t("retry"), action: retry)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.tPrimary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var picker: some View {
        HStack(spacing: 4) {
            pickerButton(.live, store.t("discover_live"))
            pickerButton(.clips, store.t("discover_clips"))
        }
        .padding(4)
        .background(Color.black.opacity(0.45))
        .clipShape(Capsule())
    }

    private func pickerButton(_ m: Mode, _ title: String) -> some View {
        Button {
            guard mode != m else { return }
            feed.stop()
            mode = m
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(mode == m ? .black : .white)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(mode == m ? Color.white : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: – Défilement vertical par page
/// Une page par écran, qu'on fait défiler vers le haut : un TabView en pages
/// tourné d'un quart de tour (iOS 16 n'a pas de défilement par page
/// vertical), ses pages tournées en sens inverse.
private struct VerticalPager<Page: View>: View {
    let count: Int
    @Binding var index: Int
    let size: CGSize
    @ViewBuilder let page: (Int) -> Page

    var body: some View {
        TabView(selection: $index) {
            ForEach(0..<count, id: \.self) { i in
                page(i)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .rotationEffect(.degrees(-90))
                    .frame(width: size.height, height: size.width)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(width: size.height, height: size.width)
        .rotationEffect(.degrees(90), anchor: .topLeading)
        .offset(x: size.width)
    }
}

// MARK: – Page d'un live
private struct DiscoverLivePage: View {
    let stream: TwitchStream
    let isCurrent: Bool
    @ObservedObject var feed: DiscoverFeed
    let onOpen: () -> Void
    @EnvironmentObject private var store: AppStore

    private var login: String { stream.userLogin.lowercased() }
    private var key: String { "live:" + login }
    private var thumb: String {
        stream.thumbnailURL
            .replacingOccurrences(of: "{width}", with: "640")
            .replacingOccurrences(of: "{height}", with: "360")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            DiscoverBackdrop(url: thumb)
            VStack(spacing: 0) {
                Spacer(minLength: 60)
                DiscoverScreen(thumb: thumb, isCurrent: isCurrent, key: key, feed: feed)
                    .onTapGesture(perform: onOpen)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 12) {
                info
                Spacer(minLength: 0)
                DiscoverSideBar(login: login, name: stream.userName, avatar: feed.avatars[login],
                                viewers: stream.viewerCount, gameId: stream.gameId, gameName: stream.gameName,
                                link: "https://www.twitch.tv/\(login)")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(store.t("live_badge"))
                    .font(.system(size: 11, weight: .heavy)).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.tLive).cornerRadius(4)
                Text("● " + formatViewers(stream.viewerCount))
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85))
            }
            HStack(spacing: 10) {
                Text(stream.userName)
                    .font(.system(size: 19, weight: .bold)).foregroundColor(.white).lineLimit(1)
                DiscoverFollowButton(login: login, channelId: stream.id)
            }
            if !stream.title.isEmpty {
                Text(stream.title)
                    .font(.system(size: 14)).foregroundColor(.white.opacity(0.9)).lineLimit(2)
            }
            let tags = stream.tags.prefix(3)
            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(tags), id: \.self) { t in
                        Text(t)
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.16)).clipShape(Capsule())
                            .lineLimit(1)
                    }
                }
            }
            if !stream.gameName.isEmpty {
                Label(stream.gameName, systemImage: "gamecontroller")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: – Page d'un clip
private struct DiscoverClipPage: View {
    let clip: FeedClip
    let isCurrent: Bool
    @ObservedObject var feed: DiscoverFeed
    let onOpen: () -> Void
    @EnvironmentObject private var store: AppStore

    private var key: String { "clip:" + clip.id }

    var body: some View {
        ZStack(alignment: .bottom) {
            DiscoverBackdrop(url: clip.thumbnailURL)
            VStack(spacing: 0) {
                Spacer(minLength: 60)
                DiscoverScreen(thumb: clip.thumbnailURL, isCurrent: isCurrent, key: key, feed: feed)
                    .onTapGesture(perform: onOpen)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("▶ " + formatViewers(clip.viewCount) + " · " + formatDuration(clip.durationSeconds))
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                    HStack(spacing: 10) {
                        Text(clip.channelName)
                            .font(.system(size: 19, weight: .bold)).foregroundColor(.white).lineLimit(1)
                        DiscoverFollowButton(login: clip.login.lowercased(), channelId: clip.channelId)
                    }
                    if !clip.title.isEmpty {
                        Text(clip.title)
                            .font(.system(size: 14)).foregroundColor(.white.opacity(0.9)).lineLimit(2)
                    }
                    if !clip.game.isEmpty {
                        Label(clip.game, systemImage: "gamecontroller")
                            .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                DiscoverSideBar(login: clip.login.lowercased(), name: clip.channelName, avatar: clip.avatar,
                                viewers: nil, gameId: "", gameName: "",
                                link: "https://clips.twitch.tv/\(clip.id)")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
    }
}

// MARK: – Éléments communs
/// Fond de page : la miniature, floutée et assombrie. L'image « remplir »
/// est dans un calque : seule, elle prenait sa propre taille (bien plus
/// large que l'écran), la page s'élargissait d'autant, la vidéo devenait
/// géante et les infos partaient hors de l'écran.
private struct DiscoverBackdrop: View {
    let url: String

    var body: some View {
        Color.black
            .overlay(
                AsyncImage(url: URL(string: url)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.black
                }
                .blur(radius: 30)
            )
            .overlay(Color.black.opacity(0.55))
            .overlay(
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
            )
            .clipped()
    }
}

/// L'image en 16:9 : la miniature, et l'aperçu par-dessus sur la page affichée.
private struct DiscoverScreen: View {
    let thumb: String
    let isCurrent: Bool
    let key: String
    @ObservedObject var feed: DiscoverFeed
    @EnvironmentObject private var store: AppStore

    var body: some View {
        // Boîte 16:9 de la largeur de la page ; la miniature et la vidéo sont
        // des calques, qui ne changent pas sa taille.
        Color.white.opacity(0.06)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(
                AsyncImage(url: URL(string: thumb)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            )
            .overlay {
                if isCurrent, feed.playing == key {
                    DiscoverVideoLayer(player: feed.player)
                }
            }
            .overlay {
                if isCurrent, feed.preview[key] == .loading {
                    ProgressView().tint(.white)
                } else if feed.preview[key] == .failed {
                    Text(store.t("discover_no_preview"))
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.black.opacity(0.6)).clipShape(Capsule())
                }
            }
            // Son coupé : le lecteur complet l'a, d'un toucher.
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                    .padding(7)
                    .background(Color.black.opacity(0.55)).clipShape(Circle())
                    .padding(8)
            }
            .clipped()
        .contentShape(Rectangle())
        .accessibilityLabel(store.t("discover_tap"))
        .accessibilityAddTraits(.isButton)
    }
}

/// Colonne de droite : photo de la chaîne, spectateurs, partager, masquer.
private struct DiscoverSideBar: View {
    let login: String
    let name: String
    let avatar: String?
    let viewers: Int?
    let gameId: String
    let gameName: String
    let link: String
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                AsyncImage(url: URL(string: avatar ?? "")) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.white.opacity(0.12))
                }
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                if let viewers {
                    HStack(spacing: 3) {
                        Circle().fill(Color.tLive).frame(width: 7, height: 7)
                        Text(formatViewers(viewers))
                            .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                    }
                }
            }
            if let url = URL(string: link) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
            }
            Menu {
                Button(role: .destructive) {
                    store.hideChannel(login: login, name: name)
                } label: {
                    Label(store.t("hide_channel"), systemImage: "eye.slash")
                }
                if !gameId.isEmpty, !gameName.isEmpty {
                    Button(role: .destructive) {
                        store.hideCategory(id: gameId, name: gameName, box: "")
                    } label: {
                        Label(store.t("hide_category").replacingOccurrences(of: "{c}", with: gameName),
                              systemImage: "eye.slash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .bold)).foregroundColor(.white)
                    .frame(width: 44, height: 44)
            }
        }
    }
}

/// Suivre la chaîne : sur Twitch avec la session web, sinon sur l'appareil
/// (comme la page de chaîne). Ne plus suivre se confirme.
private struct DiscoverFollowButton: View {
    let login: String
    let channelId: String
    @EnvironmentObject private var store: AppStore
    @StateObject private var follow = FollowService()
    @State private var confirm = false

    var body: some View {
        Group {
            if let on = follow.isFollowing {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if on {
                        confirm = true
                        return
                    }
                    Task { @MainActor in
                        await follow.toggle(token: store.twitchWebToken)
                        if follow.isFollowing == true { store.unhideChannel(login) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: on ? "heart.fill" : "heart")
                        Text(store.t(on ? "following" : "follow"))
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(on ? .tDanger : .white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(follow.busy)
                .confirmationDialog(
                    store.t("unfollow_confirm").replacingOccurrences(of: "{c}", with: login),
                    isPresented: $confirm, titleVisibility: .visible
                ) {
                    Button(store.t("unfollow"), role: .destructive) {
                        Task { @MainActor in await follow.unfollow(token: store.twitchWebToken) }
                    }
                    Button(store.t("cancel"), role: .cancel) {}
                }
            }
        }
        .task(id: login) {
            if let web = store.twitchWebToken, !channelId.isEmpty {
                await follow.load(login: login, channelId: channelId, token: web)
            } else {
                follow.loadLocal(login: login, store: store)
            }
        }
    }
}

/// Image de l'aperçu : transparente tant qu'aucune image n'est arrivée (la
/// miniature reste visible dessous), et sans réaction au toucher (la page
/// s'ouvre d'un toucher).
private final class DiscoverLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct DiscoverVideoLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> DiscoverLayerUIView {
        let v = DiscoverLayerUIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ uiView: DiscoverLayerUIView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}
