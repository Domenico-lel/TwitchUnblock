import SwiftUI
import UIKit

// MARK: – Drops de la chaîne
/// Campagne de drops active sur la chaîne regardée, pour la carte « Drops »
/// en haut du chat (comme dans l'app Twitch). Lecture publique (GQL), sans
/// compte : nom, récompenses, temps de visionnage, échéance.
struct DropsCampaignNotice: Equatable, Identifiable {
    let id: String
    let name: String
    let game: String
    let endsAt: Date?
    let detailsURL: URL?
    /// Première récompense de la campagne et ce qu'il faut regarder pour l'avoir.
    let rewardName: String
    let rewardImage: String?
    let minutes: Int
    /// Récompenses suivantes de la même campagne.
    let more: Int
}

@MainActor
final class ChannelDropsNotice: ObservableObject {
    @Published private(set) var campaign: DropsCampaignNotice?

    private var channelId = ""
    private var task: Task<Void, Never>?
    /// Campagnes dont on a fermé la carte : elle ne revient pas.
    private static let dismissedKey = "drops_notice_dismissed"

    /// Lue à l'arrivée, puis toutes les 10 minutes (une campagne peut
    /// commencer pendant le live).
    func start(channelId: String) {
        stop()
        guard !channelId.isEmpty else { return }
        self.channelId = channelId
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetch()
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        campaign = nil
    }

    func dismiss(_ c: DropsCampaignNotice) {
        var ids = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        if !ids.contains(c.id) { ids.append(c.id) }
        UserDefaults.standard.set(Array(ids.suffix(100)), forKey: Self.dismissedKey)
        campaign = nil
    }

    private func fetch() async {
        let cid = channelId
        let q = """
        query { user(id: "\(gqlStr(cid))") { channel { viewerDropCampaigns {
          id name endAt detailsURL game { displayName }
          timeBasedDrops { name requiredMinutesWatched benefitEdges { benefit { name imageAssetURL } } }
        } } } }
        """
        guard let json = await VodChatService.rawGQL(q),
              let d = json["data"] as? [String: Any],
              let user = d["user"] as? [String: Any],
              let channel = user["channel"] as? [String: Any],
              cid == channelId else { return }
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let found = (channel["viewerDropCampaigns"] as? [[String: Any]] ?? []).compactMap { c -> DropsCampaignNotice? in
            guard let id = c["id"] as? String, !dismissed.contains(id) else { return nil }
            let end = (c["endAt"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            if let end, end < Date() { return nil }
            let drops = (c["timeBasedDrops"] as? [[String: Any]] ?? [])
                .sorted { ($0["requiredMinutesWatched"] as? Int ?? 0) < ($1["requiredMinutesWatched"] as? Int ?? 0) }
            let first = drops.first
            let benefit = ((first?["benefitEdges"] as? [[String: Any]])?.first?["benefit"]) as? [String: Any]
            let game = (c["game"] as? [String: Any])?["displayName"] as? String ?? ""
            return DropsCampaignNotice(
                id: id,
                name: c["name"] as? String ?? "",
                game: game,
                endsAt: end,
                detailsURL: (c["detailsURL"] as? String).flatMap { $0.hasPrefix("https://") ? URL(string: $0) : nil },
                rewardName: (benefit?["name"] as? String) ?? (first?["name"] as? String) ?? "",
                rewardImage: benefit?["imageAssetURL"] as? String,
                minutes: first?["requiredMinutesWatched"] as? Int ?? 0,
                more: max(0, drops.count - 1))
        }
        if campaign != found.first { campaign = found.first }
    }
}

/// Carte « Drops » en haut du chat : à fermer, avec un lien vers les détails.
struct DropsNoticeCard: View {
    let campaign: DropsCampaignNotice
    let onDismiss: () -> Void
    @EnvironmentObject private var store: AppStore

    private var headline: String {
        guard !campaign.rewardName.isEmpty, campaign.minutes > 0 else { return campaign.name }
        return store.t("drops_notice_title")
            .replacingOccurrences(of: "{m}", with: "\(campaign.minutes)")
            .replacingOccurrences(of: "{r}", with: campaign.rewardName)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: URL(string: campaign.rewardImage ?? "")) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "gift.fill").font(.system(size: 18)).foregroundColor(.tPurple)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text([campaign.name, campaign.game].filter { !$0.isEmpty }.joined(separator: " · ")
                     + (campaign.more > 0 ? " · " + store.t("drops_notice_more").replacingOccurrences(of: "{n}", with: "\(campaign.more)") : ""))
                    .font(.system(size: 11)).foregroundColor(.tMuted).lineLimit(1)
                HStack(spacing: 10) {
                    if let end = campaign.endsAt {
                        Text(store.t("drops_notice_ends").replacingOccurrences(
                            of: "{d}", with: end.formatted(.dateTime.day().month(.abbreviated).hour().minute())))
                            .font(.system(size: 10)).foregroundColor(.tMuted)
                    }
                    if let url = campaign.detailsURL {
                        Button(store.t("drops_notice_details")) { UIApplication.shared.open(url) }
                            .font(.system(size: 11, weight: .bold)).foregroundColor(.tPrimary)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.tMuted)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.t("close"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.tCard)
        .overlay(Divider().background(Color.tBorder), alignment: .bottom)
    }
}

// MARK: – Fiche d'une emote ou d'un badge
/// Ce qu'on touche dans un message : une emote ou un badge.
enum ChatInfoItem: Identifiable {
    case emote(TwitchEmote)
    case badge(TwitchBadge)

    var id: String {
        switch self {
        case .emote(let e): return "emote:\(e.source.rawValue):\(e.id)"
        case .badge(let b): return "badge:\(b.id)"
        }
    }
}

private struct ChatInfoActionKey: EnvironmentKey {
    static let defaultValue: ((ChatInfoItem) -> Void)? = nil
}

extension EnvironmentValues {
    /// Fourni par le chat qui affiche les messages : un toucher sur une emote
    /// ou un badge ouvre sa fiche. Absent ailleurs (rien ne se passe).
    var chatInfoAction: ((ChatInfoItem) -> Void)? {
        get { self[ChatInfoActionKey.self] }
        set { self[ChatInfoActionKey.self] = newValue }
    }
}

extension View {
    /// Toucher → fiche, seulement si un chat la propose : sinon le geste
    /// prendrait le toucher destiné au message.
    @ViewBuilder
    func chatInfoTap(_ action: ((ChatInfoItem) -> Void)?, _ item: @escaping @autoclosure () -> ChatInfoItem) -> some View {
        if let action { onTapGesture { action(item()) } } else { self }
    }
}

/// Nom exact (à copier), source et image en grand, ou titre d'un badge.
struct ChatInfoSheet: View {
    let item: ChatInfoItem
    let channelId: String?
    /// Ajouter l'emote au message en cours (nil si on ne peut pas écrire).
    var onInsert: ((TwitchEmote) -> Void)? = nil

    @EnvironmentObject private var store: AppStore
    @State private var badge: (title: String, description: String)? = nil
    @State private var copied = false

    var body: some View {
        VStack(spacing: 12) {
            switch item {
            case .emote(let e):
                CachedEmoteImage(url: Self.largeURL(e), name: e.name, height: 72)
                Text(e.name)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.tText)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                Text(sourceLabel(e)).font(.system(size: 13)).foregroundColor(.tMuted)
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = e.name
                        copied = true
                    } label: {
                        Label(store.t(copied ? "chat_info_copied" : "chat_info_copy"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent).tint(.tPrimary)
                    if let onInsert {
                        Button { onInsert(e) } label: {
                            Label(store.t("chat_info_insert"), systemImage: "text.cursor")
                        }
                        .buttonStyle(.bordered).tint(.tPrimary)
                    }
                }
                .font(.system(size: 14, weight: .semibold))
            case .badge(let b):
                CachedEmoteImage(url: b.url, name: "", height: 54, showsNameFallback: false)
                Text(badge?.title ?? Self.fallbackTitle(b))
                    .font(.system(size: 20, weight: .bold)).foregroundColor(.tText)
                    .multilineTextAlignment(.center)
                if let d = badge?.description, !d.isEmpty, d != badge?.title {
                    Text(d).font(.system(size: 13)).foregroundColor(.tMuted)
                        .multilineTextAlignment(.center)
                }
                Text(store.t("chat_info_badge")).font(.system(size: 12)).foregroundColor(.tMuted)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .task {
            if case .badge(let b) = item {
                badge = await BadgeService.shared.info(badgeId: b.id, channelId: channelId)
            }
        }
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
    }

    private func sourceLabel(_ e: TwitchEmote) -> String {
        switch e.source {
        case .twitch: return store.t("emote_src_twitch")
        case .bttv: return e.personal ? store.t("emote_src_bttv_personal") : "BetterTTV"
        case .ffz: return "FrankerFaceZ"
        case .seventv: return "7TV"
        }
    }

    /// Image plus grande que celle du chat, quand la source la propose.
    static func largeURL(_ e: TwitchEmote) -> String {
        switch e.source {
        case .twitch: return e.url.replacingOccurrences(of: "/2.0", with: "/3.0")
        case .bttv: return e.url.replacingOccurrences(of: "/2x", with: "/3x")
        case .seventv: return e.url.replacingOccurrences(of: "/2x.", with: "/4x.")
        case .ffz: return e.url
        }
    }

    /// Sans titre connu : le nom du jeu de badges (« subscriber »…).
    static func fallbackTitle(_ b: TwitchBadge) -> String {
        let set = b.id.components(separatedBy: "/").first ?? b.id
        return set.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
