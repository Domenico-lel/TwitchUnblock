import SwiftUI

// MARK: – Chaînes notifiées
//
// Les notifications de live (réveils de l'app par iOS, ntfy) couvrent les
// chaînes suivies — compte Twitch et appareil —, moins celles coupées ici.
// La liste reste sur l'appareil : le Worker ne reçoit que les chaînes à
// notifier (NtfyNotifier.sync). Une chaîne suivie plus tard est notifiée
// d'office.
enum NotifChannels {
    static let mutedKey = "notif_muted"

    static var muted: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: mutedKey) ?? [])
    }

    static func setMuted(_ logins: Set<String>) {
        UserDefaults.standard.set(logins.sorted(), forKey: mutedKey)
    }
}

/// Réglages → Fonctionnalités en test → Chaînes notifiées : un interrupteur
/// par chaîne suivie, allumé par défaut.
struct NotifChannelsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var channels: [ChannelBrief] = []
    @State private var muted = NotifChannels.muted
    @State private var loading = true
    @State private var failed = false
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                } else if channels.isEmpty {
                    Text(store.t(failed ? "notif_channels_error" : "notif_channels_none"))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .listRowBackground(Color.tCard)
                } else {
                    Section {
                        HStack {
                            Button(store.t("notif_channels_all_on")) { setAll(notify: true) }
                            Spacer()
                            Button(store.t("notif_channels_all_off")) { setAll(notify: false) }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.tPrimary)
                    } footer: {
                        Text(store.t("notif_channels_sub"))
                    }
                    .listRowBackground(Color.tCard)
                    Section {
                        ForEach(shown) { row($0) }
                    }
                    .listRowBackground(Color.tCard)
                }
            }
            .searchable(text: $search)
            .scrollContentBackground(.hidden)
            .background(Color.tDark)
            .navigationTitle(store.t("notif_channels"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.t("close")) { dismiss() }
                }
            }
        }
        .task { await load() }
        // ntfy : la liste filtrée part au Worker (rien si elle n'a pas changé).
        .onDisappear {
            let lang = store.lang
            Task { await NtfyNotifier.sync(lang: lang) }
        }
    }

    private var shown: [ChannelBrief] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return channels }
        return channels.filter { $0.login.contains(q) || $0.name.lowercased().contains(q) }
    }

    private func row(_ c: ChannelBrief) -> some View {
        Toggle(isOn: Binding(get: { !muted.contains(c.login) },
                             set: { setNotify(c.login, $0) })) {
            HStack(spacing: 10) {
                AsyncImage(url: URL(string: c.avatar)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.tSurface)
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                Text(c.name).font(.tBody).foregroundColor(.tText).lineLimit(1)
            }
        }
        .tint(.tPrimary)
    }

    private func setNotify(_ login: String, _ on: Bool) {
        var next = muted
        if on { next.remove(login) } else { next.insert(login) }
        muted = next
        NotifChannels.setMuted(next)
    }

    private func setAll(notify: Bool) {
        let next: Set<String> = notify ? [] : Set(channels.map(\.login))
        muted = next
        NotifChannels.setMuted(next)
        logger.settingChanged("Chaînes notifiées", value: notify ? "toutes" : "aucune")
    }

    /// Suivies du compte (s'il y en a un) et de l'appareil, avec nom et avatar ;
    /// sans réponse de Twitch pour ces derniers, les identifiants seuls.
    private func load() async {
        let ud = UserDefaults.standard
        var logins = ud.stringArray(forKey: "local_follows") ?? []
        if let token = Keychain.loadToken("twitch_token"),
           let userId = ud.string(forKey: "twitch_user_id"), !userId.isEmpty {
            guard let account = await getFollowedLogins(token: token, userId: userId) else {
                failed = true
                loading = false
                return
            }
            logins += account
        }
        var seen = Set<String>()
        let unique = logins.map { $0.lowercased() }.filter { seen.insert($0).inserted }
        let infos = await getChannelsGQL(logins: unique)
            ?? unique.map { ChannelBrief(login: $0, name: $0, avatar: "", stream: nil) }
        channels = infos
            .map { ChannelBrief(login: $0.login.lowercased(), name: $0.name, avatar: $0.avatar, stream: nil) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        loading = false
    }
}
