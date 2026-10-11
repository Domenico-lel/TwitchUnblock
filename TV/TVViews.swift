import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Écrans de l'app Apple TV : onglets en haut, cartes à la télécommande
//  (style « card » de tvOS : la carte qui a le focus se soulève).
// ═══════════════════════════════════════════════════════════════════════════

/// Ce que le lecteur doit lire.
enum TVPlayback: Identifiable, Hashable {
    case live(login: String, name: String)
    case vod(id: String, title: String)

    var id: String {
        switch self {
        case .live(let login, _): return "live-\(login)"
        case .vod(let id, _):     return "vod-\(id)"
        }
    }
}

struct TVRootView: View {
    @EnvironmentObject private var session: TVSession
    @State private var playing: TVPlayback?

    var body: some View {
        TabView {
            TVFollowingTab(play: play)
                .tabItem { Text(session.t("tv_following")) }
            TVTopTab(play: play)
                .tabItem { Text(session.t("tv_top")) }
            TVCategoriesTab(play: play)
                .tabItem { Text(session.t("tv_categories")) }
            TVSearchTab(play: play)
                .tabItem { Text(session.t("tv_search")) }
            TVAccountTab()
                .tabItem { Text(session.t("tv_account")) }
        }
        .fullScreenCover(item: $playing) { item in
            TVPlayerScreen(item: item)
                .environmentObject(session)
        }
        .task { await session.restore() }
    }

    private func play(_ item: TVPlayback) { playing = item }
}

// MARK: – Suivies
struct TVFollowingTab: View {
    let play: (TVPlayback) -> Void
    @EnvironmentObject private var session: TVSession
    @State private var streams: [TwitchStream] = []
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if session.token == nil {
                    TVMessage(text: session.t("tv_need_login"))
                } else if streams.isEmpty {
                    TVMessage(text: loading ? session.t("loading")
                              : (failed ? session.t("tv_error") : session.t("tv_no_live")))
                } else {
                    TVStreamGrid(streams: streams, play: play)
                }
            }
        }
        // Relancé quand le compte arrive (connexion, ou lancement).
        .task(id: session.user?.id) { await load() }
    }

    private func load() async {
        guard let uid = session.user?.id, let token = session.token else { streams = []; return }
        loading = true
        defer { loading = false }
        if let list = try? await getFollowedStreams(token: token, userId: uid) {
            streams = list
            failed = false
        } else if let fresh = await session.renewToken(),
                  let list = try? await getFollowedStreams(token: fresh, userId: uid) {
            // Jeton expiré : renouvelé une fois.
            streams = list
            failed = false
        } else {
            failed = true
        }
    }
}

// MARK: – Top
struct TVTopTab: View {
    let play: (TVPlayback) -> Void
    @EnvironmentObject private var session: TVSession
    @State private var worldwide = false
    @State private var streams: [TwitchStream] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Picker("", selection: $worldwide) {
                    Text(TopLanguage.name(TopLanguage.device, in: session.lang)).tag(false)
                    Text(session.t("tv_world")).tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 800)
                .padding(.top, 24)

                if streams.isEmpty {
                    TVMessage(text: loading ? session.t("loading") : session.t("tv_no_live"))
                } else {
                    TVStreamGrid(streams: streams, play: play)
                }
            }
        }
        .task(id: worldwide) {
            loading = true
            streams = await getTopStreamsGQL(lang: worldwide ? nil : TopLanguage.device)
            loading = false
        }
    }
}

// MARK: – Catégories
struct TVCategoriesTab: View {
    let play: (TVPlayback) -> Void
    @EnvironmentObject private var session: TVSession
    @State private var categories: [TwitchCategory] = []
    @State private var loaded = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 40), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                if categories.isEmpty {
                    TVMessage(text: loaded ? session.t("tv_error") : session.t("loading"))
                } else {
                    LazyVGrid(columns: columns, spacing: 48) {
                        ForEach(categories) { c in
                            NavigationLink(value: c) {
                                TVCategoryCard(category: c)
                            }
                            .tvCard()
                        }
                    }
                    .padding(.horizontal, 64)
                    .padding(.vertical, 32)
                }
            }
            .navigationDestination(for: TwitchCategory.self) { c in
                TVCategoryStreams(category: c, play: play)
            }
        }
        .task {
            guard categories.isEmpty else { return }
            categories = await getTopCategoriesGQL() ?? []
            loaded = true
        }
    }
}

struct TVCategoryCard: View {
    let category: TwitchCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVThumbnail(url: sharpBoxArt(category.boxArtURL), ratio: 3 / 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(category.name).font(.headline).lineLimit(1)
                if let v = category.viewers {
                    Text(formatViewers(v)).font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TVCategoryStreams: View {
    let category: TwitchCategory
    let play: (TVPlayback) -> Void
    @EnvironmentObject private var session: TVSession
    @State private var streams: [TwitchStream] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            Text(category.name)
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 64)
            if streams.isEmpty {
                TVMessage(text: loaded ? session.t("tv_no_live") : session.t("loading"))
            } else {
                TVStreamGrid(streams: streams, play: play)
            }
        }
        .task {
            streams = await getStreamsByCategoryGQL(gameId: category.id) ?? []
            loaded = true
        }
    }
}

// MARK: – Recherche
struct TVSearchTab: View {
    let play: (TVPlayback) -> Void
    @EnvironmentObject private var session: TVSession
    @State private var query = ""
    @State private var results: [AutocompleteSuggestion] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(results) { r in
                        NavigationLink(value: r.login) {
                            HStack(spacing: 24) {
                                TVAvatar(url: r.avatar, size: 80)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(r.name).font(.headline)
                                    if let v = r.viewers {
                                        Text(session.t("tv_live") + " · " + formatViewers(v) + (r.game.map { " · \($0)" } ?? ""))
                                            .font(.caption)
                                            .foregroundColor(Color.tLive)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                        }
                    }
                }
                .padding(.horizontal, 64)
            }
            .searchable(text: $query, prompt: session.t("tv_search_prompt"))
            .navigationDestination(for: String.self) { login in
                TVChannelView(login: login, play: play)
            }
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = []; return }
            // Une requête après la frappe, pas une par lettre.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            results = await searchUsersGQL(q)
        }
    }
}

// MARK: – Chaîne : live éventuel et VODs
struct TVChannelView: View {
    let login: String
    let play: (TVPlayback) -> Void
    @EnvironmentObject private var session: TVSession
    @State private var videos: [VodData] = []
    @State private var avatar: String?
    @State private var live: TwitchStream?
    @State private var loaded = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 28) {
                    TVAvatar(url: avatar, size: 120)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(live?.userName ?? login).font(.title2.bold())
                        if let live {
                            Text(live.title).font(.callout).foregroundColor(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if let live {
                        Button {
                            play(.live(login: login, name: live.userName))
                        } label: {
                            Label(session.t("tv_watch_live"), systemImage: "play.fill")
                        }
                    }
                }

                Text(session.t("tv_videos")).font(.title3.bold())
                if videos.isEmpty {
                    TVMessage(text: loaded ? session.t("tv_no_videos") : session.t("loading"))
                } else {
                    LazyVGrid(columns: columns, spacing: 56) {
                        ForEach(videos) { v in
                            Button {
                                play(.vod(id: v.id, title: v.title))
                            } label: {
                                TVVodCard(video: v)
                            }
                            .tvCard()
                        }
                    }
                }
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 32)
        }
        .task {
            async let channelVideos = getChannelVideos(channelName: login)
            async let liveStreams = getLiveStreamsGQL(logins: [login])
            let result = await channelVideos
            let streams = await liveStreams
            videos = result.videos
            avatar = result.avatar
            live = streams?.first
            loaded = true
        }
    }
}

// MARK: – Compte et réglages
struct TVAccountTab: View {
    @EnvironmentObject private var session: TVSession
    @State private var code: TVSession.DeviceCode?
    @State private var failed = false
    @State private var loginTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                if session.token != nil {
                    HStack(spacing: 28) {
                        TVAvatar(url: session.user?.profileImageURL, size: 120)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(session.user?.displayName ?? "…").font(.title2.bold())
                            Text(session.t("tv_logged_in")).foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(session.t("tv_logout")) { session.logout() }
                    }
                } else if let code {
                    loginPanel(code)
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(session.t("tv_login_intro")).font(.title3)
                        Button(session.t("tv_login")) { startLogin() }
                        if failed {
                            Text(session.t("tv_login_expired")).foregroundColor(Color.tWarning)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 32) {
                    Text(session.t("tv_settings")).font(.title3.bold())
                    TVChoiceRow(title: session.t("tv_language"),
                                options: Lang.allCases.map { ($0.rawValue, $0.label) },
                                selection: Binding(get: { session.lang.rawValue },
                                                   set: { session.lang = Lang(rawValue: $0) ?? .en }))
                    TVChoiceRow(title: session.t("live_source"),
                                options: kLiveSourceChoices.map { ($0, session.t("src_\($0)")) },
                                selection: $session.liveSource)
                }
            }
            .padding(64)
        }
        .onDisappear {
            loginTask?.cancel()
            loginTask = nil
            code = nil
        }
    }

    private func startLogin() {
        failed = false
        loginTask?.cancel()
        loginTask = Task {
            guard let c = await session.requestCode() else { failed = true; return }
            code = c
            let ok = await session.waitForApproval(c)
            code = nil
            if !ok && !Task.isCancelled { failed = true }
        }
    }

    private func loginPanel(_ c: TVSession.DeviceCode) -> some View {
        HStack(alignment: .center, spacing: 80) {
            if let qr = tvQRCode(c.verificationURL) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 360, height: 360)
                    .padding(20)
                    .background(Color.white)
                    .cornerRadius(16)
            }
            VStack(alignment: .leading, spacing: 24) {
                Text(session.t("tv_login_steps")).font(.title3)
                Text("twitch.tv/activate").font(.title2.bold()).foregroundColor(Color.tPurple)
                Text(session.t("tv_login_code")).font(.title3)
                Text(c.userCode)
                    .font(.system(size: 72, weight: .heavy, design: .monospaced))
                HStack(spacing: 16) {
                    ProgressView()
                    Text(session.t("tv_login_waiting")).foregroundColor(.secondary)
                }
            }
        }
    }
}

/// Un choix parmi quelques valeurs : une rangée de boutons, coche sur la valeur
/// retenue (plus simple à la télécommande qu'un menu).
struct TVChoiceRow: View {
    let title: String
    let options: [(String, String)]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline).foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(options.indices, id: \.self) { i in
                        Button {
                            selection = options[i].0
                        } label: {
                            HStack(spacing: 10) {
                                if options[i].0 == selection { Image(systemName: "checkmark") }
                                Text(options[i].1)
                            }
                        }
                    }
                }
                .padding(.vertical, 20)
            }
        }
    }
}

// MARK: – Cartes et éléments communs
struct TVStreamGrid: View {
    let streams: [TwitchStream]
    let play: (TVPlayback) -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 48), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 56) {
            ForEach(streams) { s in
                Button {
                    play(.live(login: s.userLogin, name: s.userName))
                } label: {
                    TVStreamCard(stream: s)
                }
                .tvCard()
            }
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 32)
    }
}

struct TVStreamCard: View {
    let stream: TwitchStream
    @EnvironmentObject private var session: TVSession

    private var thumb: String {
        stream.thumbnailURL
            .replacingOccurrences(of: "{width}", with: "640")
            .replacingOccurrences(of: "{height}", with: "360")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                TVThumbnail(url: thumb, ratio: 16 / 9)

                HStack(spacing: 8) {
                    Text(session.t("tv_live"))
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.tLive)
                        .cornerRadius(4)
                    Text(formatViewers(stream.viewerCount))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(4)
                }
                .foregroundColor(.white)
                .padding(12)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(stream.userName).font(.headline).lineLimit(1)
                Text(stream.title).font(.caption).foregroundColor(.secondary).lineLimit(2)
                if !stream.gameName.isEmpty {
                    Text(stream.gameName).font(.caption2).foregroundColor(Color.tPurple).lineLimit(1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TVVodCard: View {
    let video: VodData

    private var thumb: String {
        video.previewThumbnailURL
            .replacingOccurrences(of: "%{width}", with: "640")
            .replacingOccurrences(of: "%{height}", with: "360")
            .replacingOccurrences(of: "{width}", with: "640")
            .replacingOccurrences(of: "{height}", with: "360")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                TVThumbnail(url: thumb, ratio: 16 / 9)

                Text(formatDuration(video.lengthSeconds))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                    .padding(12)
            }
            Text(video.title)
                .font(.caption)
                .lineLimit(2)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Image d'une carte dans une boîte au format fixe, qu'elle remplit et où
/// elle est rognée. Sans boîte, une miniature en « remplir » reprenait sa
/// taille d'origine (640 points) au chargement ou au focus, et débordait sur
/// la carte voisine.
struct TVThumbnail: View {
    let url: String
    let ratio: CGFloat

    var body: some View {
        Color.white.opacity(0.08)
            .aspectRatio(ratio, contentMode: .fit)
            .overlay(
                AsyncImage(url: URL(string: url)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            )
            .clipped()
    }
}

/// Carte à la télécommande (style « card » de tvOS) : celle qui a le focus
/// grandit et passe devant ses voisines, au lieu de glisser dessous.
private struct TVCardFocus: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .buttonStyle(.card)
            .focused($focused)
            .zIndex(focused ? 1 : 0)
    }
}

extension View {
    func tvCard() -> some View { modifier(TVCardFocus()) }
}

struct TVAvatar: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Circle().fill(Color.white.opacity(0.1))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct TVMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title3)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(80)
    }
}
