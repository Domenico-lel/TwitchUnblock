import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Multi-live : la mosaïque (plein écran), et ce qui sert à la composer —
//  l'appui long sur une carte de direct, le « + » des cartes une fois un
//  premier direct choisi.
// ═══════════════════════════════════════════════════════════════════════════

struct MultiLiveView: View {
    /// Ouvrir un direct dans le lecteur (avec le chat) : la mosaïque se ferme.
    let onWatch: (String) -> Void

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var multi = MultiLive.shared
    @StateObject private var session = MultiLiveSession()
    @State private var showAdd = false
    @State private var addName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                layout(portrait: geo.size.height > geo.size.width)
                    .padding(4)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            session.sync(multi.entries)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onChange(of: multi.entries) { list in
            if list.isEmpty { dismiss() } else { session.sync(list) }
        }
        .onDisappear {
            session.stopAll()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .alert(store.t("multi_add_channel"), isPresented: $showAdd) {
            TextField(store.t("multi_add_ph"), text: $addName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(store.t("cancel"), role: .cancel) { addName = "" }
            Button(store.t("multi_add_ok")) {
                multi.add(addName, name: addName.trimmingCharacters(in: .whitespaces))
                addName = ""
            }
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
            if !multi.isFull {
                TIconButton(icon: "plus") { showAdd = true }
            }
            TIconButton(icon: "xmark") { dismiss() }
        }
        .padding(.horizontal, TSpace.lg)
        .padding(.vertical, TSpace.sm)
        .background(Color.tDark)
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
        if let model = session.tiles[entry.login] {
            MultiLiveTile(entry: entry, model: model,
                          audible: session.audible == entry.login,
                          onTap: { session.audible = entry.login },
                          onRemove: { multi.remove(entry.login) },
                          onWatch: { onWatch(entry.login) })
        } else {
            Color.black
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

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            PlayerLayerView(player: model.player)
            state
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
                Text(store.t(model.phase == .offline ? "multi_offline" : "multi_failed"))
                    .font(.tMeta).foregroundColor(.tMuted)
                    .multilineTextAlignment(.center)
                Button { model.retry() } label: {
                    Label(store.t("multi_retry"), systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.tText)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(Capsule().stroke(Color.tBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(TSpace.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .playing:
            EmptyView()
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 12, weight: .bold))
            Text(entry.name).lineLimit(1)
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

/// « + » / « ✓ » sur une carte de direct, dès qu'un premier direct est choisi
/// (le premier se choisit par appui long, ou depuis le lecteur).
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
