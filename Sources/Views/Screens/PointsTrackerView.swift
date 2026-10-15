import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Réglages → Points de chaîne : temps regardé et points gagnés en regardant,
//  en ce moment, au total et par chaîne (PointsTracker), comme les drops.
// ═══════════════════════════════════════════════════════════════════════════

struct PointsTrackerPanel: View {
    /// Ouvre la connexion à la session web (gérée par SettingsView).
    var onLogin: () -> Void = {}

    @EnvironmentObject private var store: AppStore
    @ObservedObject private var tracker = PointsTracker.shared
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 12) {
            if store.twitchWebToken == nil {
                VStack(alignment: .leading, spacing: TSpace.md) {
                    Text(store.t("pt_login")).font(.tMeta).foregroundColor(.tMuted)
                    TPrimaryButton(title: store.t("web_banner_btn")) { onLogin() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tCard()
            }
            if !tracker.sessions.isEmpty { nowCard }
            totalCard
            if tracker.channels.isEmpty {
                Text(store.t("pt_empty"))
                    .font(.tMeta).foregroundColor(.tMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tCard()
            } else {
                channelsCard
            }
            Text(store.t("pt_note"))
                .font(.tMeta).foregroundColor(.tMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TSpace.xs)
            if !tracker.channels.isEmpty {
                Button(role: .destructive) { confirmReset = true } label: {
                    Text(store.t("pt_reset")).font(.tLabel).foregroundColor(.tLive)
                }
                .confirmationDialog(store.t("pt_reset_confirm"), isPresented: $confirmReset, titleVisibility: .visible) {
                    Button(store.t("pt_reset"), role: .destructive) { tracker.reset() }
                }
            }
        }
    }

    /// Chaînes qui rapportent en ce moment, depuis l'ouverture de leur chat.
    private var nowCard: some View {
        VStack(alignment: .leading, spacing: TSpace.sm) {
            Label(store.t("pt_now"), systemImage: "dot.radiowaves.left.and.right")
                .font(.tCardTitle).foregroundColor(.tLive)
            ForEach(tracker.sessions.values.sorted { $0.start < $1.start }) { s in
                HStack {
                    Text(s.login).font(.tBody.weight(.semibold)).foregroundColor(.tText).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(duration(s.minutes)) · +\(number(s.points))")
                        .font(.tMeta.monospacedDigit()).foregroundColor(.tMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tCard()
    }

    private var totalCard: some View {
        VStack(alignment: .leading, spacing: TSpace.md) {
            HStack {
                Text(store.t("pt_total")).font(.tCardTitle).foregroundColor(.tText)
                Spacer(minLength: 8)
                if let since = tracker.since {
                    Text(store.t("pt_since").replacingOccurrences(of: "{d}", with: date(since)))
                        .font(.tMeta).foregroundColor(.tMuted)
                }
            }
            HStack(spacing: TSpace.sm) {
                stat("clock.fill", store.t("pt_watched"), duration(tracker.totalMinutes), .tPrimary)
                stat("circle.circle.fill", store.t("pt_earned"), "+" + number(tracker.totalPoints), .tPurple)
                stat("gift.fill", store.t("pt_chests"), number(tracker.totalChests), .tWarning)
            }
        }
        .tCard()
    }

    private func stat(_ icon: String, _ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon).font(.tMeta).foregroundColor(tint).lineLimit(1)
            Text(value)
                .font(.system(size: 17, weight: .bold).monospacedDigit()).foregroundColor(.tText)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Par chaîne, la plus récemment regardée en haut.
    private var channelsCard: some View {
        let list = tracker.channels.values.sorted { $0.last > $1.last }
        return VStack(alignment: .leading, spacing: 0) {
            Text(store.t("pt_channels")).font(.tCardTitle).foregroundColor(.tText)
                .padding(.bottom, TSpace.xs)
            ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Divider().background(Color.tBorder) }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.login).font(.tBody.weight(.semibold)).foregroundColor(.tText).lineLimit(1)
                        Text(relative(c.last)).font(.tMeta).foregroundColor(.tMuted)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("+" + number(c.points)).font(.tLabel.monospacedDigit()).foregroundColor(.tPurple)
                        Text(duration(c.minutes) + (c.chests > 0 ? " · 🎁 \(c.chests)" : ""))
                            .font(.tMeta.monospacedDigit()).foregroundColor(.tMuted)
                    }
                }
                .padding(.vertical, TSpace.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tCard()
    }

    // MARK: Formats (langue de l'app)
    private var locale: Locale { Locale(identifier: store.lang.rawValue) }

    /// 45 min, 3 h 20 min…
    private func duration(_ minutes: Int) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .abbreviated
        var cal = Calendar.current
        cal.locale = locale
        f.calendar = cal
        return f.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
    }

    private func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        return f.string(from: d)
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}
