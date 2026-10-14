import SwiftUI

/// Tris disponibles sur les lives d'une catégorie.
/// Helix ne renvoie que l'ordre « plus de spectateurs d'abord » : les autres
/// sont appliqués localement sur la page chargée.
enum StreamSort: String, CaseIterable, Identifiable {
    case viewersDesc, viewersAsc, nameAsc

    var id: String { rawValue }

    func label(_ store: AppStore) -> String {
        switch self {
        case .viewersDesc: return store.t("sort_viewers_desc")
        case .viewersAsc:  return store.t("sort_viewers_asc")
        case .nameAsc:     return store.t("sort_name")
        }
    }

    var icon: String {
        switch self {
        case .viewersDesc: return "arrow.down"
        case .viewersAsc:  return "arrow.up"
        case .nameAsc:     return "textformat.abc"
        }
    }

    func apply(_ streams: [TwitchStream]) -> [TwitchStream] {
        switch self {
        case .viewersDesc: return streams.sorted { $0.viewerCount > $1.viewerCount }
        case .viewersAsc:  return streams.sorted { $0.viewerCount < $1.viewerCount }
        case .nameAsc:
            return streams.sorted {
                $0.userName.localizedCaseInsensitiveCompare($1.userName) == .orderedAscending
            }
        }
    }
}

// MARK: – « Charger plus » sans compte
/// Curseur de la suite d'une liste : GQL sans jeton (Client-ID d'Android,
/// kGQLNextClientID) ou Helix avec le compte (`nil` : Helix depuis le début).
/// Les deux ne se mélangent pas : un curseur GQL envoyé à Helix, ou
/// l'inverse, serait refusé après une connexion en cours de route.
enum ListCursor: Equatable {
    case gql(String)
    case helix(String?)
}

/// Charge la suite d'une liste à partir de `cursor`. Jusqu'à 3 pages pour
/// trouver du neuf : les pages se recouvrent un peu d'un Client-ID à l'autre,
/// les lives bougent, et Helix repart du début après un refus de GQL.
/// - `gql` : une page après ce curseur ; nil = panne réseau.
/// - `helix` : une page avec le jeton, après ce curseur (nil = début) ; nil = panne.
/// Renvoie les éléments absents de `current`, le curseur suivant (le même
/// après une panne : le bouton reste pour réessayer), et `locked` : Twitch
/// refuse la suite et aucun compte ne peut prendre le relais.
@MainActor func loadMorePages<T: Identifiable>(
    after cursor: ListCursor, current: [T], token: String?,
    gql: (String) async -> (items: [T], next: String?, refused: Bool)?,
    helix: (String, String?) async -> (items: [T], next: String?)?
) async -> (fresh: [T], cursor: ListCursor?, locked: Bool) {
    var c: ListCursor? = cursor
    var seen = Set(current.map(\.id))
    var fresh: [T] = []
    for _ in 0..<3 {
        guard let step = c else { break }
        switch step {
        case .gql(let after):
            guard let page = await gql(after) else { return (fresh, c, false) }
            if page.refused {
                // Twitch refuse aussi ce Client-ID : Helix avec le compte,
                // depuis le début ; sans compte, la liste s'arrête là.
                guard token != nil else { return (fresh, nil, true) }
                c = .helix(nil)
                continue
            }
            fresh += page.items.filter { seen.insert($0.id).inserted }
            c = page.next.map { ListCursor.gql($0) }
        case .helix(let after):
            guard let token else { return (fresh, nil, false) }
            guard let page = await helix(token, after) else { return (fresh, c, false) }
            fresh += page.items.filter { seen.insert($0.id).inserted }
            c = page.next.map { ListCursor.helix($0) }
        }
        if !fresh.isEmpty { break }
    }
    return (fresh, c, false)
}

// MARK: – Grille des catégories
struct CategoriesView: View {
    let onPlayStream: (String) -> Void

    @EnvironmentObject private var store: AppStore

    @State private var categories: [TwitchCategory] = []
    @State private var cursor: ListCursor? = nil
    /// Twitch refuse la suite sans compte : un message remplace le bouton.
    @State private var locked       = false
    @State private var loading      = false
    @State private var loadingMore  = false
    @State private var errorMsg: String? = nil
    @State private var search       = ""
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var selected: TwitchCategory? = nil
    /// 0 = catégories suivies, 1 = toutes.
    @AppStorage("cat_tab") private var tab = 1
    /// Suivies sur Twitch (session web), complétées par celles de l'appareil.
    @State private var twitchFollowed: [TwitchCategory] = []
    @State private var followedViewers: [String: Int] = [:]
    @State private var loadingFollowed = false

    /// Suivies : Twitch puis appareil, sans doublon.
    private var followedList: [TwitchCategory] {
        var seen = Set<String>()
        return (twitchFollowed + store.followedCategories)
            .filter { seen.insert($0.id).inserted }
            .map { c in var c = c; c.viewers = c.viewers ?? followedViewers[c.id]; return c }
            .sorted { ($0.viewers ?? 0) > ($1.viewers ?? 0) }
    }

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        Group {
            if let cat = selected {
                CategoryStreamsView(category: cat,
                                    onBack: { selected = nil },
                                    onPlayStream: onPlayStream)
            } else {
                browser
            }
        }
        .onAppear {
            if categories.isEmpty { Task { await loadTop() } }
            Task { await loadFollowed() }
        }
        .onChange(of: store.followedCategories.map(\.id)) { _ in Task { await loadFollowed() } }
    }

    /// Catégories suivies : Twitch (si session web) + appareil, avec audience.
    @MainActor private func loadFollowed() async {
        if let web = store.twitchWebToken {
            if twitchFollowed.isEmpty { loadingFollowed = true }
            if let list = await getFollowedCategoriesGQL(webToken: web) { twitchFollowed = list }
            loadingFollowed = false
        }
        let missing = store.followedCategories.map(\.id)
        guard !missing.isEmpty else { return }
        let counts = await categoryViewers(ids: missing)
        if !counts.isEmpty { followedViewers = counts }
    }

    // MARK: – Onglet « Suivies »
    @ViewBuilder private var followedGrid: some View {
        let list = followedList
        if loadingFollowed && list.isEmpty {
            Spacer(); TLoader(); Spacer()
        } else if list.isEmpty {
            Spacer()
            TEmptyState(icon: "heart", title: store.t("cat_followed_empty"),
                        message: store.t(store.twitchWebToken == nil ? "cat_followed_empty_msg_local" : "cat_followed_empty_msg"))
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: TSpace.md) {
                    ForEach(list) { cat in
                        CategoryCardView(category: cat) { selected = cat }
                    }
                }
                .padding(.horizontal, TSpace.lg)
                .padding(.top, TSpace.md)
                Spacer(minLength: 40)
            }
            .refreshable { await Task { await loadFollowed() }.value }
        }
    }

    // MARK: – Liste / recherche
    @ViewBuilder private var browser: some View {
        VStack(spacing: 0) {
            // Suivies | Toutes
            HStack(spacing: TSpace.sm) {
                TChip(title: store.t("cat_followed"), isOn: tab == 0) { tab = 0 }
                TChip(title: store.t("cat_all"), isOn: tab == 1) { tab = 1 }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TSpace.lg)
            .padding(.top, TSpace.md)

            if tab == 0 {
                followedGrid
            } else {
                allBrowser
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tDark)
    }

    @ViewBuilder private var allBrowser: some View {
        VStack(spacing: 0) {
            TSearchField(text: $search, placeholder: store.t("cat_search_ph"))
                .padding(.horizontal, TSpace.lg)
                .padding(.top, TSpace.md)
                .onChange(of: search) { runSearch($0) }

            if loading {
                Spacer()
                TLoader()
                Spacer()
            } else if let err = errorMsg {
                Spacer()
                TEmptyState(icon: "exclamationmark.triangle", title: err)
                Spacer()
            } else if categories.isEmpty {
                Spacer()
                TEmptyState(icon: "magnifyingglass", title: store.t("no_result"))
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: TSpace.md) {
                        ForEach(categories) { cat in
                            CategoryCardView(category: cat) { selected = cat }
                        }
                    }
                    .padding(.horizontal, TSpace.lg)
                    .padding(.top, TSpace.md)

                    // Pagination : uniquement sur le Top (la recherche n'en a pas).
                    if search.isEmpty {
                        if cursor != nil {
                            TLoadMoreButton(busy: loadingMore) { Task { await loadMore() } }
                        } else if locked {
                            TListEndNote(key: "more_needs_login")
                        }
                    }

                    Spacer(minLength: 40)
                }
                .refreshable { await loadTop() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tDark)
    }

    // MARK: – Chargements
    @MainActor private func loadTop() async {
        if categories.isEmpty { loading = true }
        errorMsg = nil
        guard let token = store.twitchToken else {
            // Sans compte : GQL public, audience comprise, par pages de 100 ;
            // la suite passe par le Client-ID d'Android (loadMore).
            if let page = await getTopCategoriesPageGQL(after: nil) {
                categories = page.categories
                cursor = page.next.map { ListCursor.gql($0) }
                locked = false
            } else if categories.isEmpty {
                errorMsg = store.t("err_loading")
            }
            loading = false
            return
        }
        do {
            let page = try await getTopCategories(token: token)
            categories = page.categories
            cursor     = page.cursor.map { ListCursor.helix($0) }
            locked     = false
        } catch is CancellationError {
            loading = false; return
        } catch {
            errorMsg = store.t("err_loading")
        }
        loading = false
        await loadViewers()
    }

    /// Complète les cartes avec l'audience de chaque catégorie. Séparé du
    /// chargement : Helix ne la donne pas, et la grille ne doit pas attendre
    /// une seconde requête pour s'afficher.
    @MainActor private func loadViewers() async {
        let missing = categories.filter { $0.viewers == nil }.map(\.id)
        guard !missing.isEmpty else { return }
        let counts = await categoryViewers(ids: missing)
        guard !counts.isEmpty else { return }
        for i in categories.indices where categories[i].viewers == nil {
            categories[i].viewers = counts[categories[i].id]
        }
    }

    /// Suite du Top : GQL sans compte, Helix avec ; doublons écartés (Twitch
    /// en renvoie entre deux pages).
    @MainActor private func loadMore() async {
        guard let c = cursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let result = await loadMorePages(
            after: c, current: categories, token: store.twitchToken,
            gql: { after in
                guard let p = await getTopCategoriesPageGQL(after: after) else { return nil }
                return (p.categories, p.next, p.refused)
            },
            helix: { token, after in
                guard let p = try? await getTopCategories(token: token, cursor: after) else { return nil }
                return (p.categories, p.cursor)
            })
        // Recherche lancée entre-temps : elle a remplacé la grille.
        guard search.isEmpty else { return }
        categories += result.fresh
        cursor = result.cursor
        locked = result.locked
        await loadViewers()
    }

    /// Recherche différée de 350 ms : évite un appel par frappe.
    private func runSearch(_ text: String) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            searchTask = Task { await loadTop() }
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            // GQL d'abord, avec ou sans compte : le classement de Twitch
            // (« valorant » donne VALORANT en tête) et des jaquettes nettes.
            // Helix classait mal et renvoyait des vignettes de 52×72 : il ne
            // sert plus que de secours, si GQL ne répond pas.
            var result = await searchCategoriesGQL(query: q)
            if result == nil, let token = store.twitchToken {
                result = try? await searchCategories(token: token, query: q)
            }
            guard let found = result.map({ rankCategories($0, for: q) }), !Task.isCancelled else { return }
            await MainActor.run {
                categories = found
                cursor     = nil
                errorMsg   = nil
            }
            // La recherche passe par Helix elle aussi : mêmes cartes, donc
            // même complément d'audience.
            guard !Task.isCancelled else { return }
            await loadViewers()
        }
    }
}

// MARK: – Lives d'une catégorie
struct CategoryStreamsView: View {
    let category: TwitchCategory
    let onBack: () -> Void
    let onPlayStream: (String) -> Void

    @EnvironmentObject private var store: AppStore

    @State private var streams: [TwitchStream] = []
    @State private var cursor: ListCursor? = nil
    /// Twitch refuse la suite sans compte : un message remplace le bouton.
    @State private var locked      = false
    @State private var loading     = false
    @State private var loadingMore = false
    @State private var errorMsg: String? = nil
    @State private var sort: StreamSort = .viewersDesc

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    private var sorted: [TwitchStream] { sort.apply(streams) }

    var body: some View {
        VStack(spacing: 0) {

            // ── En-tête : retour + nom de la catégorie ──────────────
            HStack(spacing: TSpace.sm) {
                Button(action: onBack) {
                    HStack(spacing: TSpace.xs) {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                        Text(store.t("categories")).font(.tLabel)
                    }
                    .foregroundColor(.tPrimary)
                }
                .buttonStyle(.plain)

                Text(category.name)
                    .font(.tSection)
                    .foregroundColor(.tText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // Suivre la catégorie (gardé sur cet appareil).
                let on = store.isCategoryFollowed(category.id)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.15)) { store.toggleCategoryFollow(category) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: on ? "heart.fill" : "heart")
                        Text(store.t(on ? "following" : "follow")).font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(on ? .tDanger : .tPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background((on ? Color.tDanger : Color.tPrimary).opacity(0.14))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, TSpace.lg)
            .padding(.top, TSpace.md)
            .padding(.bottom, TSpace.sm)

            // ── Langue et tri ───────────────────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TSpace.sm) {
                    languageMenu
                    ForEach(StreamSort.allCases) { s in
                        TChip(title: s.label(store), icon: s.icon, isOn: sort == s) { sort = s }
                    }
                }
                .padding(.horizontal, TSpace.lg)
            }
            .padding(.bottom, TSpace.md)

            if loading {
                Spacer()
                TLoader()
                Spacer()
            } else if let err = errorMsg {
                Spacer()
                TEmptyState(icon: "exclamationmark.triangle", title: err)
                Spacer()
            } else if streams.isEmpty {
                Spacer()
                TEmptyState(icon: "antenna.radiowaves.left.and.right",
                            title: store.t("no_live"))
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: TSpace.md) {
                        ForEach(sorted) { stream in
                            StreamCardView(stream: stream) { onPlayStream(stream.userLogin) }
                        }
                    }
                    .padding(.horizontal, TSpace.lg)

                    if cursor != nil {
                        TLoadMoreButton(busy: loadingMore) { Task { await loadMore() } }
                    } else if locked {
                        TListEndNote(key: "more_needs_login")
                    }

                    Spacer(minLength: 40)
                }
                .refreshable { await load() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tDark)
        .onAppear { if streams.isEmpty { Task { await load() } } }
        .onChange(of: store.categoryLang) { _ in
            streams = []
            cursor = nil
            locked = false
            Task { await load() }
        }
    }

    /// Langue des lives (la même pour toutes les catégories) : toutes, celle
    /// de l'appareil, ou une autre.
    private var languageMenu: some View {
        let current = store.categoryLang
        let device = TopLanguage.device
        let others = TopLanguage.codes
            .filter { $0 != device }
            .map { ($0, TopLanguage.name($0, in: store.lang)) }
            .sorted { $0.1.localizedCompare($1.1) == .orderedAscending }
        return Menu {
            Button { store.categoryLang = nil } label: {
                if current == nil { Label(store.t("cat_lang_all"), systemImage: "checkmark") }
                else { Text(store.t("cat_lang_all")) }
            }
            Button { store.categoryLang = device } label: {
                if current == device { Label(TopLanguage.name(device, in: store.lang), systemImage: "checkmark") }
                else { Text(TopLanguage.name(device, in: store.lang)) }
            }
            Divider()
            ForEach(others, id: \.0) { code, name in
                Button { store.categoryLang = code } label: {
                    if current == code { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            HStack(spacing: TSpace.xs) {
                Image(systemName: "globe").font(.system(size: 11, weight: .semibold))
                Text(current.map { TopLanguage.name($0, in: store.lang) } ?? store.t("cat_lang_all"))
                    .font(.tLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(current == nil ? .tMuted : .white)
            .padding(.horizontal, TSpace.md)
            .frame(height: 32)
            .background(current == nil ? Color.tSurface : Color.tPrimary)
            .cornerRadius(TRadius.chip)
        }
    }

    @MainActor private func load() async {
        if streams.isEmpty { loading = true }
        errorMsg = nil
        guard let token = store.twitchToken else {
            // Sans compte : les lives les plus regardés (GQL public) par pages
            // de 100 ; la suite passe par le Client-ID d'Android (loadMore).
            if let page = await getStreamsByCategoryPageGQL(gameId: category.id, lang: store.categoryLang, after: nil) {
                streams = page.streams
                cursor = page.next.map { ListCursor.gql($0) }
                locked = false
            } else if streams.isEmpty {
                errorMsg = store.t("err_loading")
            }
            loading = false
            return
        }
        do {
            let page = try await getStreamsByCategory(token: token, gameId: category.id, lang: store.categoryLang)
            streams = page.streams
            cursor  = page.cursor.map { ListCursor.helix($0) }
            locked  = false
        } catch is CancellationError {
            loading = false; return
        } catch {
            errorMsg = store.t("err_loading")
        }
        loading = false
    }

    /// Suite des lives : GQL sans compte, Helix avec ; doublons écartés (les
    /// lives bougent d'une page à l'autre).
    @MainActor private func loadMore() async {
        guard let c = cursor, !loadingMore else { return }
        let lang = store.categoryLang
        let gameId = category.id
        loadingMore = true
        defer { loadingMore = false }
        let result = await loadMorePages(
            after: c, current: streams, token: store.twitchToken,
            gql: { after in
                guard let p = await getStreamsByCategoryPageGQL(gameId: gameId, lang: lang, after: after) else { return nil }
                return (p.streams, p.next, p.refused)
            },
            helix: { token, after in
                guard let p = try? await getStreamsByCategory(token: token, gameId: gameId, cursor: after, lang: lang)
                else { return nil }
                return (p.streams, p.cursor)
            })
        // Langue changée entre-temps : la liste a été rechargée.
        guard lang == store.categoryLang else { return }
        streams += result.fresh
        cursor = result.cursor
        locked = result.locked
    }
}
