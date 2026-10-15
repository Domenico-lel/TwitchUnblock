import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Multi-live : la mosaïque (plein écran), et ce qui sert à la composer —
//  l'appui long sur une carte de direct ou de VOD, le « + » des cartes de
//  direct une fois une première vidéo choisie.
// ═══════════════════════════════════════════════════════════════════════════

struct MultiLiveView: View {
    /// Ouvrir une vidéo dans le lecteur (avec le chat) : la mosaïque se ferme.
    /// Une VOD y reprend à la position de sa tuile.
    let onWatch: (MultiLiveEntry, Double) -> Void

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    /// Large (iPad, grand iPhone en paysage) : place pour le chat.
    @Environment(\.horizontalSizeClass) private var widthClass
    /// Arrière-plan : positions des VODs enregistrées, lecteurs relancés au retour.
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var multi = MultiLive.shared
    @StateObject private var session = MultiLiveSession()
    @State private var showAdd = false
    @State private var addName = ""
    /// Saisie du « + » refusée : le message à afficher.
    @State private var addError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                let chatWidth = chatModel == nil ? 0 : min(360, geo.size.width * 0.32)
                HStack(spacing: 0) {
                    layout(portrait: geo.size.height > geo.size.width - chatWidth)
                        .padding(4)
                    if let model = chatModel {
                        Rectangle().fill(Color.tBorder).frame(width: 1)
                        MultiLiveChatPane(model: model)
                            .frame(width: chatWidth - 1)
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            // Abonné sans pub : chaque direct passe par le compte (AppStore).
            session.accountToken = { [store] in store.accountPlaybackWebToken(for: $0) }
            // VODs : reprise et progression comme dans le lecteur ; au premier
            // démarrage d'une tuile, sa chaîne et son titre, et l'historique.
            session.configure(
                resume: { [store] in store.getVodProgress($0) },
                save: { [store] id, t in store.setVodProgress(id, time: t) },
                onStarted: { [store] id, meta in Self.vodStarted(id, meta, store: store) })
            session.sync(multi.entries)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onChange(of: multi.entries) { list in
            if list.isEmpty { dismiss() } else { session.sync(list) }
        }
        .onChange(of: scenePhase) { session.sceneChanged($0) }
        .onDisappear {
            session.stopAll()
            // Fin de visionnage : la progression des VODs part maintenant,
            // comme à la fermeture du lecteur.
            store.flushToCloud(force: true)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .alert(store.t("multi_add_channel"), isPresented: $showAdd) {
            TextField(store.t("multi_add_ph"), text: $addName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(store.t("cancel"), role: .cancel) { addName = "" }
            Button(store.t("multi_add_ok")) { addFromInput() }
        }
    }

    /// VOD lancée pour la première fois dans sa tuile : ce que Twitch en dit
    /// complète l'entrée, et elle entre dans l'historique (sans quoi sa
    /// progression ne partirait pas dans la synchro).
    @MainActor private static func vodStarted(_ id: String, _ meta: VodMeta?, store: AppStore) {
        let multi = MultiLive.shared
        if let meta {
            multi.updateVod(id: id, login: meta.login,
                            name: meta.login.isEmpty ? "" : meta.streamer,
                            title: meta.title, thumb: meta.thumb)
        }
        let entry = multi.entries.first { $0.vodId == id }
        let thumb = meta.map(\.thumb).flatMap { $0.isEmpty ? nil : $0 } ?? entry?.thumb
        let streamer = entry.flatMap { $0.login.isEmpty ? ($0.name.isEmpty ? nil : $0.name) : $0.login }
        store.saveToHistory(HistoryItem(
            term: id, type: .vod,
            display: meta?.title ?? entry?.title ?? "VOD \(id)",
            thumb: thumb, streamer: streamer,
            addedAt: Date().timeIntervalSince1970 * 1000
        ))
    }

    /// « + » : une VOD (lien ou ID), sinon une chaîne (nom, « @nom » ou lien).
    private func addFromInput() {
        let raw = addName.trimmingCharacters(in: .whitespaces)
        addName = ""
        guard !raw.isEmpty else { return }
        var error: String? = nil
        if isVodInput(raw) {
            // Titre et chaîne : complétés au démarrage de la tuile.
            if let id = extractVodId(raw) { multi.addVod(id: id, name: "") }
            else { error = store.t("err_bad_vod") }
        } else {
            let login = loginFromInput(raw)
            if isValidLogin(login) { multi.add(login, name: login) }
            else { error = store.t("not_found") }
        }
        // Après la fermeture de la saisie : une alerte n'en remplace pas une
        // autre en train de partir.
        if let message = error {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { addError = message }
        }
    }

    private var header: some View {
        HStack(spacing: TSpace.md) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.tPurple)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.t("multi_title")).font(.tSection).foregroundColor(.tText)
                Text(store.t("multi_hint")).font(.tMeta).foregroundColor(.tMuted).lineLimit(1)
            }
            Spacer(minLength: TSpace.sm)
            if widthClass == .regular {
                TIconButton(icon: store.multiLiveChat ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right",
                            tint: store.multiLiveChat ? .tPurple : .tMuted) {
                    store.multiLiveChat.toggle()
                }
            }
            if !multi.isFull {
                TIconButton(icon: "plus") { showAdd = true }
            }
            TIconButton(icon: "xmark") { dismiss() }
        }
        .padding(.horizontal, TSpace.lg)
        .padding(.vertical, TSpace.sm)
        .background(Color.tDark)
        .alert(addError ?? "", isPresented: Binding(get: { addError != nil },
                                                   set: { if !$0 { addError = nil } })) {
            Button("OK", role: .cancel) { addError = nil }
        }
    }

    /// La vidéo qui a le son, si son chat a la place de s'afficher.
    private var chatModel: MultiTileModel? {
        guard store.multiLiveChat, widthClass == .regular, let id = session.audible else { return nil }
        return session.tiles[id]
    }

    /// Côte à côte en largeur (le premier en grand à trois, 2 × 2 à quatre),
    /// les uns sous les autres en hauteur.
    @ViewBuilder private func layout(portrait: Bool) -> some View {
        let list = multi.entries
        if list.count == 2 && !portrait {
            HStack(spacing: 4) { tile(list[0]); tile(list[1]) }
        } else if list.count == 3 && !portrait {
            HStack(spacing: 4) {
                tile(list[0])
                VStack(spacing: 4) { tile(list[1]); tile(list[2]) }
            }
        } else if list.count == 4 && !portrait {
            VStack(spacing: 4) {
                HStack(spacing: 4) { tile(list[0]); tile(list[1]) }
                HStack(spacing: 4) { tile(list[2]); tile(list[3]) }
            }
        } else {
            VStack(spacing: 4) { ForEach(list) { tile($0) } }
        }
    }

    @ViewBuilder private func tile(_ entry: MultiLiveEntry) -> some View {
        if let model = session.tiles[entry.id] {
            MultiLiveTile(entry: entry, model: model,
                          audible: session.audible == entry.id,
                          onTap: { session.audible = entry.id },
                          onRemove: { multi.remove(id: entry.id) },
                          onWatch: { onWatch(entry, model.position) })
        } else {
            Color.black
        }
    }
}

// MARK: – Chat de la vidéo qui a le son
private struct MultiLiveChatPane: View {
    @ObservedObject var model: MultiTileModel
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if let vodId = model.vodId {
            // VOD : son chat rejoué, à la position de la tuile.
            VodChatView(videoId: vodId, playbackTime: model.position,
                        style: store.chatStyle(chrome: true, translucent: false))
                .id("vod-\(vodId)")
        } else {
            ChatView(channelName: model.login, channelId: model.channelId,
                     token: store.twitchToken, login: store.twitchLogin,
                     chatOnly: .constant(false),
                     style: store.chatStyle(chrome: true, translucent: false),
                     // Mosaïque plein écran : la page d'une chaîne s'ouvrirait
                     // dessous, sans qu'on la voie.
                     opensChannelPages: false)
                // Autre direct, ou identifiant arrivé : chat reconstruit à neuf.
                .id("\(model.login)-\(model.channelId ?? "")")
        }
    }
}

// MARK: – Une tuile
struct MultiLiveTile: View {
    let entry: MultiLiveEntry
    @ObservedObject var model: MultiTileModel
    let audible: Bool
    let onTap: () -> Void
    let onRemove: () -> Void
    let onWatch: () -> Void

    @EnvironmentObject private var store: AppStore
    /// Position glissée sur la barre d'une VOD, cherchée au lâcher.
    @State private var scrub: Double? = nil
    @State private var scrubbing = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            PlayerLayerView(player: model.player)
            state
            AdBreakBanner(watcher: model.adBreaks, compact: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(8)
            if model.isVod {
                vodBottom
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            bar
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(audible ? Color.tPrimary : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder private var state: some View {
        switch model.phase {
        case .loading:
            ProgressView().tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .offline, .failed:
            VStack(spacing: 10) {
                Text(store.t(model.isVod ? "multi_vod_failed"
                             : model.phase == .offline ? "multi_offline" : "multi_failed"))
                    .font(.tMeta).foregroundColor(.tMuted)
                    .multilineTextAlignment(.center)
                stateButton("multi_retry", icon: "arrow.clockwise") { model.retry() }
            }
            .padding(TSpace.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ended:
            VStack(spacing: 10) {
                Text(store.t("multi_vod_ended"))
                    .font(.tMeta).foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                stateButton("multi_replay", icon: "arrow.counterclockwise") { model.replay() }
            }
            .padding(TSpace.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.55))
        case .playing:
            // VOD en pause sans le son : rien ne le dirait autrement.
            if model.isVod && model.userPaused && !audible {
                Image(systemName: "pause.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(store.t("multi_pause"))
            }
        }
    }

    private func stateButton(_ key: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(store.t(key), systemImage: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.tText)
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().stroke(Color.tBorder, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 12, weight: .bold))
            if entry.isVod {
                Text("VOD")
                    .font(.system(size: 10, weight: .heavy))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.tPurple))
            }
            Text(entry.displayName).lineLimit(1)
            Spacer(minLength: 4)
            tileButton("arrow.up.left.and.arrow.down.right", action: onWatch)
            tileButton("xmark", action: onRemove)
        }
        .font(.system(size: 13, weight: .bold))
        .foregroundColor(.white)
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
        .padding(.bottom, 10)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
    }

    private func tileButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.black.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    // MARK: VOD
    /// Tuile qui a le son : la barre de commandes, toujours visible (comme la
    /// barre du haut). Les autres : un trait de progression.
    @ViewBuilder private var vodBottom: some View {
        if audible {
            vodControls
        } else if model.duration > 0 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.5)
                    Color.tPrimary.frame(width: geo.size.width * min(1, model.position / model.duration))
                }
            }
            .frame(height: 3)
        }
    }

    private var vodControls: some View {
        let shown = scrub ?? model.position
        let end = max(1, model.duration)
        let paused = model.userPaused || model.phase == .ended
        return HStack(spacing: 0) {
            controlButton("gobackward.10", label: "multi_back10") { model.seek(by: -10) }
            controlButton(model.phase == .ended ? "arrow.counterclockwise" : paused ? "play.fill" : "pause.fill",
                          label: model.phase == .ended ? "multi_replay" : paused ? "multi_play" : "multi_pause") {
                model.togglePlay()
            }
            controlButton("goforward.10", label: "multi_fwd10") { model.seek(by: 10) }
            Slider(value: Binding(get: { min(shown, end) },
                                  set: { v in
                                      scrub = v
                                      // Réglée sans glisser (VoiceOver) : cherchée tout de suite.
                                      if !scrubbing { model.seek(to: v); scrub = nil }
                                  }),
                   in: 0...end,
                   onEditingChanged: { editing in
                       scrubbing = editing
                       guard !editing, let s = scrub else { return }
                       model.seek(to: s)
                       scrub = nil
                   })
                .tint(.tPrimary)
                .disabled(model.duration <= 0)
                .padding(.horizontal, 4)
            Text("\(VodChatService.formatOffset(shown)) / \(VodChatService.formatOffset(model.duration))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(.white)
                .lineLimit(1).fixedSize()
                .padding(.trailing, 8)
        }
        .padding(.top, 14)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
    }

    /// Bouton de la barre d'une VOD : 44 pt de zone tactile, libellé VoiceOver.
    private func controlButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.t(label))
    }
}

// MARK: – Composer le multi-live
/// Appui long sur une carte de direct : l'ajouter au multi-live, ou l'en retirer.
struct MultiLiveMenuButton: View {
    let login: String
    let name: String

    @EnvironmentObject private var store: AppStore
    @ObservedObject private var multi = MultiLive.shared

    var body: some View {
        if multi.contains(login) {
            Button(role: .destructive) { multi.remove(login) } label: {
                Label(store.t("multi_remove"), systemImage: "minus.square")
            }
        } else {
            Button { multi.add(login, name: name) } label: {
                Label(multi.isFull ? store.t("multi_full") : store.t("multi_add"), systemImage: "square.grid.2x2")
            }
            .disabled(multi.isFull)
        }
    }
}

/// Appui long sur une VOD (cartes d'une chaîne, Mes VODs) : l'ajouter au
/// multi-live, ou l'en retirer. `login` : la chaîne si on la connaît (sinon
/// la tuile la complète à son démarrage).
struct MultiVodMenuButton: View {
    let vodId: String
    let title: String?
    let thumb: String?
    let name: String
    var login: String = ""

    @EnvironmentObject private var store: AppStore
    @ObservedObject private var multi = MultiLive.shared

    var body: some View {
        if multi.containsVod(vodId) {
            Button(role: .destructive) { multi.remove(id: "vod:\(vodId)") } label: {
                Label(store.t("multi_remove"), systemImage: "minus.square")
            }
        } else {
            Button { multi.addVod(id: vodId, name: name, title: title, thumb: thumb, login: login) } label: {
                Label(multi.isFull ? store.t("multi_full") : store.t("multi_add"), systemImage: "square.grid.2x2")
            }
            .disabled(multi.isFull)
        }
    }
}

/// « + » / « ✓ » sur une carte de direct, dès qu'une première vidéo est
/// choisie (la première se choisit par appui long, ou depuis le lecteur).
struct MultiLiveCardToggle: View {
    let login: String
    let name: String

    @ObservedObject private var multi = MultiLive.shared

    var body: some View {
        if !multi.entries.isEmpty {
            let on = multi.contains(login)
            Button {
                multi.toggle(login, name: name)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: on ? "checkmark" : "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(on ? Color.tPrimary : Color.black.opacity(0.65)))
            }
            .buttonStyle(.plain)
            .disabled(!on && multi.isFull)
        }
    }
}
