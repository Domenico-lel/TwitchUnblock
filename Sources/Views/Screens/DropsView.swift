import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Réglages → Drops : réglages, drop en cours, campagnes et réclamation.
//  Tout passe par la session web, comme les points de chaîne (voir Drops.swift).
// ═══════════════════════════════════════════════════════════════════════════

struct DropsPanel: View {
    /// Ouvre la connexion à la session web (gérée par SettingsView).
    var onLogin: () -> Void = {}

    @EnvironmentObject private var store: AppStore
    @ObservedObject private var drops = DropsService.shared
    @Environment(\.openURL) private var openURL

    private var webToken: String? {
        guard let t = store.twitchWebToken, !t.isEmpty else { return nil }
        return t
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                toggleRow(store.t("drops_progress"), store.t("drops_progress_sub"), $store.dropsProgress)
                Divider().background(Color.tBorder)
                toggleRow(store.t("drops_autoclaim"), store.t("drops_autoclaim_sub"), $store.autoClaimDrops)
            }
            .tCard()

            if let token = webToken {
                if let notice = drops.notice {
                    Text(notice.text)
                        .font(.tMeta.weight(.semibold))
                        .foregroundColor(notice.ok ? .tSuccess : .tLive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tCard()
                }
                if let s = drops.session { sessionCard(s) }
                campaignsList(token: token)
            } else {
                VStack(alignment: .leading, spacing: TSpace.md) {
                    Text(store.t("drops_login"))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    TPrimaryButton(title: store.t("web_banner_btn")) { onLogin() }
                }
                .tCard()
            }
        }
        .task { await reload() }
        .onChange(of: store.twitchWebToken) { _ in Task { await reload() } }
        .onChange(of: store.dropsProgress) { on in
            logger.settingChanged("Drops : progression", value: on ? "activée" : "désactivée")
            if !on { DropsHeartbeat.shared.stop() }
        }
        .onChange(of: store.autoClaimDrops) { on in
            logger.settingChanged("Drops : réclamation auto", value: on ? "activée" : "désactivée")
        }
        .onDisappear { drops.notice = nil }
    }

    private func reload() async {
        guard let token = webToken else { return }
        await drops.refresh(token: token, autoClaim: store.autoClaimDrops)
    }

    // MARK: Drop en cours
    private func sessionCard(_ s: DropSession) -> some View {
        HStack(spacing: TSpace.md) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .semibold)).foregroundColor(.tLive)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.t("drops_now").replacingOccurrences(of: "{c}", with: s.channelName ?? "—"))
                    .font(.tCardTitle).foregroundColor(.tText)
                Text(minutes(s.currentMinutes, s.requiredMinutes))
                    .font(.tMeta).foregroundColor(.tMuted)
            }
            Spacer(minLength: 0)
        }
        .tCard()
    }

    // MARK: Campagnes
    @ViewBuilder
    private func campaignsList(token: String) -> some View {
        HStack {
            Text(store.t("drops_in_progress"))
                .font(.tSection).foregroundColor(.tText)
            Spacer()
            if drops.isLoading {
                ProgressView().tint(.tPrimary)
            } else {
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.tPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.t("drops_refresh"))
            }
        }
        .padding(.horizontal, 4)

        if drops.campaigns.isEmpty {
            Text(drops.failed ? store.t("drops_error") : (drops.loaded ? store.t("drops_empty") : store.t("loading")))
                .font(.tMeta).foregroundColor(.tMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tCard()
        }
        ForEach(drops.campaigns) { c in campaignCard(c, token: token) }
    }

    private func campaignCard(_ c: DropCampaign, token: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: TSpace.md) {
                AsyncImage(url: URL(string: c.boxArtURL)) { img in
                    img.resizable().aspectRatio(3/4, contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.tSurface)
                }
                .frame(width: 36, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name)
                        .font(.tCardTitle).foregroundColor(.tText)
                        .lineLimit(2)
                    Text(c.gameName)
                        .font(.tMeta).foregroundColor(.tPurple)
                        .lineLimit(1)
                    if let end = c.endAt {
                        Text(store.t("drops_ends").replacingOccurrences(of: "{d}", with: relative(end)))
                            .font(.tMeta).foregroundColor(.tMuted)
                    }
                }
                Spacer(minLength: 0)
            }

            // Sans liaison du compte de jeu, Twitch ne donne plus la récompense.
            if c.needsAccountLink {
                HStack(alignment: .top, spacing: TSpace.sm) {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.tWarning)
                    Text(store.t("drops_link"))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let link = c.accountLinkURL, let url = URL(string: link) {
                        Button(store.t("drops_link_btn")) { openURL(url) }
                            .font(.tMeta.weight(.semibold))
                            .foregroundColor(.tPrimary)
                            .buttonStyle(.plain)
                    }
                }
            }

            ForEach(c.drops) { d in dropRow(d, campaign: c, token: token) }
        }
        .tCard()
    }

    private func dropRow(_ d: TimedDrop, campaign c: DropCampaign, token: String) -> some View {
        HStack(spacing: TSpace.md) {
            AsyncImage(url: URL(string: d.imageURL ?? "")) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                RoundedRectangle(cornerRadius: 8).fill(Color.tSurface)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(d.name)
                    .font(.tCardTitle).foregroundColor(.tText)
                    .lineLimit(2)
                ProgressView(value: d.progress)
                    .tint(d.isClaimed ? .tSuccess : .tPrimary)
                Text(d.hasPreconditionsMet ? minutes(d.currentMinutes, d.requiredMinutes) : store.t("drops_locked"))
                    .font(.tMeta).foregroundColor(.tMuted)
            }

            Spacer(minLength: 8)

            if d.isClaimed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20)).foregroundColor(.tSuccess)
                    .accessibilityLabel(store.t("drops_claimed"))
            } else if d.canClaim && !c.needsAccountLink {
                Button {
                    Task {
                        if await drops.claim(d, token: token) {
                            await drops.refresh(token: token, autoClaim: false)
                        }
                    }
                } label: {
                    Group {
                        if drops.claiming.contains(d.id) {
                            ProgressView().tint(.white)
                        } else {
                            Text(store.t("drops_claim"))
                        }
                    }
                    .font(.tMeta.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.tPrimary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(drops.claiming.contains(d.id))
            }
        }
    }

    // MARK: Aides
    private func toggleRow(_ title: String, _ sub: String, _ isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.tCardTitle).foregroundColor(.tText)
                Text(sub)
                    .font(.tMeta).foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().tint(.tPrimary)
        }
    }

    private func minutes(_ current: Int, _ required: Int) -> String {
        store.t("drops_minutes")
            .replacingOccurrences(of: "{n}", with: "\(required > 0 ? min(current, required) : current)")
            .replacingOccurrences(of: "{t}", with: "\(required)")
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: store.lang.rawValue)
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
